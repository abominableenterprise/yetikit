#!/usr/bin/env bash
# Stop must remove runner-private state without wiping a foreign editor's shared files.
set -euo pipefail
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
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
editor_ready() { [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$UNITY_BIN" ]; }
fixtures_present() {
  [ -f "$SHM_DIR/udsMem-fixture" ] && [ -f "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ -f "$PROJECT/Temp/UnityLockfile" ]
}
fixtures_absent() {
  [ ! -e "$SHM_DIR/udsMem-fixture" ] && [ ! -e "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ ! -e "$PROJECT/Temp/UnityLockfile" ]
}

# No inherited marker: this editor was opened outside the recorded run.
env -u LINUX_UNITY_RUN "$UNITY_BIN" 300 & foreign=$!; pids+=("$foreign")
export SHIP_FIXTURE_PIDS="${pids[*]}"
ship_wait_until editor_ready "$foreign"
for scenario in foreign alone; do
  # A synthetic recorded runner with a real executable child, no editor or licence required.
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
  owned="$(cat "$tmp/owned.pid")"; pids+=("$owned")
  export SHIP_FIXTURE_PIDS="${pids[*]}"
  ship_wait_until editor_ready "$owned"
  touch "$SHM_DIR/udsMem-fixture" "$SHM_DIR/sem.udsMem-fixture" "$PROJECT/Temp/UnityLockfile"
  rc=0; bash "$script" stop 2>"$tmp/$scenario.log" || rc=$?
  wait "$runner" 2>/dev/null || true
  check "$scenario: stop succeeds" test "$rc" = 0
  check "$scenario: recorded runner is dead" test ! -d "/proc/$runner"
  check "$scenario: recorded editor is dead" bash -c '[ ! -e "/proc/$1/exe" ]' _ "$owned"
  check "$scenario: pidfile is removed" test ! -e "$PIDFILE"
  # Reacquiring the sidecar lock also verifies stop released the private descriptor.
  check "$scenario: pidfile lock is released" flock -n "$PIDFILE.lock" true
  if [ "$scenario" = foreign ]; then
    check "foreign editor survives" alive "$foreign"
    check "all three shared fixtures survive" fixtures_present
    check "warning names the foreign PID" grep -qE "warning: Unity processes remain \(PIDs:.*\b$foreign\b" "$tmp/$scenario.log"
    kill "$foreign"; wait "$foreign" 2>/dev/null || true
  else
    check "no foreign editor: all three shared fixtures are removed" fixtures_absent
  fi
done
[ "$failures" = 0 ]
