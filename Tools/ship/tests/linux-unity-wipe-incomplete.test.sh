#!/usr/bin/env bash
# An unreadable live editor must not be mistaken for an absent shared-file owner.
set -euo pipefail
if [ ! -d /proc/self ]; then
  echo 'SKIP: incomplete-inspection cleanup checks require /proc/self'
  exit 0
fi
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/fixture.sh"
tmp="$(mktemp -d)"
pids=()
finish() {
  local pid
  for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap finish EXIT
ship_fixture "$tmp/project"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/process-view:$PATH" SHIP_FIXTURE_PIDS=''
export UNITY_ROOT="$tmp/unity" SHM_DIR="$tmp/shm"
mkdir -p "$UNITY_ROOT/Editor" "$SHM_DIR" "$PROJECT/Temp"
cp /usr/bin/sleep "$UNITY_ROOT/Editor/Unity"
. "$script"
failures=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label" >&2; failures=$((failures + 1)); fi
}
editor_ready() { [ "$(command readlink "/proc/$1/exe" 2>/dev/null)" = "$UNITY_BIN" ]; }
fixtures_present() {
  [ -f "$SHM_DIR/udsMem-fixture" ] && [ -f "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ -f "$PROJECT/Temp/UnityLockfile" ]
}
fixtures_absent() {
  [ ! -e "$SHM_DIR/udsMem-fixture" ] && [ ! -e "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ ! -e "$PROJECT/Temp/UnityLockfile" ]
}
# Reuse the process-scan test's readlink/cat seam, but target a foreign editor, not this shell.
readlink() {
  [ "$1" != "/proc/$foreign/exe" ] || return 1
  command readlink "$@"
}
cat() {
  case "$1" in
    "/proc/$foreign/status") printf 'Name:\tsynthetic\nState:\t%s (synthetic)\n%s' "$state" "$kthread" ;;
    "/proc/$foreign/stat") printf '%s (synthetic editor) %s 0 0 0 0 0 %s 0\n' "$foreign" "$state" "$fixture_flags" ;;
    *) command cat "$@" ;;
  esac
}
for operation in cleanup stop; do
  for scenario in live kernel old-kernel zombie absent; do
    env -u LINUX_UNITY_RUN "$UNITY_BIN" 300 & foreign=$!; pids+=("$foreign")
    export SHIP_FIXTURE_PIDS="${pids[*]}"
    ship_wait_until editor_ready "$foreign"
    state=S; kthread=''; fixture_flags=64
    case "$scenario" in
      kernel) kthread=$'Kthread:\t1\n' ;;
      old-kernel) fixture_flags=2097216 ;;
      zombie) state=Z ;;
      absent) kill "$foreign"; wait "$foreign" 2>/dev/null || true ;;
    esac
    if [ "$operation" = stop ]; then
      # Record a real runner and its own editor; stop must still kill both and release private state.
      rm -f "$tmp/owned.pid"
      bash -c '
        . "$1"
        lock_unity; write_pidfile
        export LINUX_UNITY_RUN="${PID_LINE/ /:}"
        "$UNITY_BIN" 300 & child=$!
        echo "$child" > "$2"
        wait "$child"
      ' _ "$script" "$tmp/owned.pid" >"$tmp/runner.log" 2>&1 & runner=$!; pids+=("$runner")
      ship_wait_until test -s "$tmp/owned.pid"
      owned="$(command cat "$tmp/owned.pid")"; pids+=("$owned")
      export SHIP_FIXTURE_PIDS="${pids[*]}"
      ship_wait_until editor_ready "$owned"
    fi
    touch "$SHM_DIR/udsMem-fixture" "$SHM_DIR/sem.udsMem-fixture" "$PROJECT/Temp/UnityLockfile"
    rc=0
    # Subshell closes the cleanup descriptor on exit, just as a command invocation does.
    (trap - EXIT; if [ "$operation" = stop ]; then cmd_stop; else cleanup_unity; fi) 2>"$tmp/$operation-$scenario.log" || rc=$?
    check "$operation/$scenario: succeeds" test "$rc" = 0
    if [ "$scenario" = live ]; then
      check "$operation: all three shared fixtures survive incomplete inspection" fixtures_present
      check "$operation: incomplete inspection warns and skips wipe" grep -qE 'warning: .*inspection incomplete.*skipping shared-memory and UnityLockfile cleanup' "$tmp/$operation-$scenario.log"
    else
      check "$operation/$scenario: all three shared fixtures are removed" fixtures_absent
    fi
    if [ "$operation" = stop ]; then
      wait "$runner" 2>/dev/null || true
      check "$scenario: recorded runner exited" test ! -d "/proc/$runner"
      check "$scenario: recorded editor exited" test ! -e "/proc/$owned/exe"
      check "$scenario: pidfile removed" test ! -e "$PIDFILE"
      check "$scenario: pidfile descriptor released" flock -n "$PIDFILE.lock" true
    fi
    if [ "$scenario" != absent ]; then kill "$foreign"; wait "$foreign" 2>/dev/null || true; fi
  done
done
[ "$failures" = 0 ]
