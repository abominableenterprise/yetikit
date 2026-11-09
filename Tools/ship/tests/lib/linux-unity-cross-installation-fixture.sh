# Synthetic cross-installation process fixture and unchanged scenario/action checks.
if [ ! -d /proc/self ]; then
  echo 'SKIP: cross-installation process checks require /proc/self'
  exit 0
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Tools/ship/tests/lib/fixture.sh
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
export UNITY_ROOT="$tmp/A" SHM_DIR="$tmp/shm"
mkdir -p "$UNITY_ROOT/Editor" "$tmp/B/Editor/Data/Tools" "$tmp/other/Editor" "$SHM_DIR" "$PROJECT/Temp"
for exe in A/Editor/Unity B/Editor/Unity B/Editor/Data/Tools/Helper unity-helper-not-editor other/Editor/helper; do
  cp /usr/bin/sleep "$tmp/$exe"
done
. "$script"
failures=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label" >&2; failures=$((failures + 1)); fi
}
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
exe_ready() { [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$2" ]; }
fixtures_present() {
  [ -f "$SHM_DIR/udsMem-fixture" ] && [ -f "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ -f "$PROJECT/Temp/UnityLockfile" ]
}
fixtures_absent() {
  [ ! -e "$SHM_DIR/udsMem-fixture" ] && [ ! -e "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ ! -e "$PROJECT/Temp/UnityLockfile" ]
}

cross_installation_scenarios() {
for scenario in "$@"; do
  foreign=''
  case "$scenario" in
    editor) exe="$tmp/B/Editor/Unity" ;;
    helper) exe="$tmp/B/Editor/Data/Tools/Helper" ;;
    name-only) exe="$tmp/unity-helper-not-editor" ;;
    unrelated-tree) exe="$tmp/other/Editor/helper" ;;
    alone) exe='' ;;
  esac
  if [ -n "$exe" ]; then
    env -u LINUX_UNITY_RUN "$exe" 300 & foreign=$!; pids+=("$foreign")
    export SHIP_FIXTURE_PIDS="${pids[*]}"
    ship_wait_until exe_ready "$foreign" "$exe"
  fi
  # Preflight still inspects only A; the broader scan is exclusively for wiping.
  check "$scenario: installation scan excludes foreign processes" bash -c '. "$1"; [ -z "$(unity_pids strict)" ]' _ "$script"
  for action in cleanup stop; do
    if [ "$action" = stop ]; then
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
      ship_wait_until exe_ready "$owned" "$UNITY_BIN"
    fi
    touch "$SHM_DIR/udsMem-fixture" "$SHM_DIR/sem.udsMem-fixture" "$PROJECT/Temp/UnityLockfile"
    log_file="$tmp/$scenario-$action.log"
    rc=0
    if [ "$action" = stop ]; then
      bash "$script" stop 2>"$log_file" || rc=$?
      wait "$runner" 2>/dev/null || true
      check "$scenario stop: pidfile removed" test ! -e "$PIDFILE"
      check "$scenario stop: recorded editor is dead" bash -c '[ ! -e "/proc/$1/exe" ]' _ "$owned"
    else
      bash -c '. "$1"; cleanup_unity' _ "$script" 2>"$log_file" || rc=$?
    fi
    check "$scenario $action: succeeds" test "$rc" = 0
    if [ -n "$foreign" ]; then check "$scenario $action: foreign process survives" alive "$foreign"; fi
    case "$scenario" in
      editor|helper)
        check "$scenario $action: shm and lockfile survive" fixtures_present
        check "$scenario $action: warning names foreign PID" grep -qE "warning: Unity processes remain \(PIDs:.*\b$foreign\b" "$log_file"
        check "$scenario $action: warning names executable path" grep -qF "$exe" "$log_file"
        check "$scenario $action: one warning line" test "$(grep -c '^\[linux-unity\] warning:' "$log_file")" = 1
        ;;
      *) check "$scenario $action: shm and lockfile removed" fixtures_absent ;;
    esac
  done
  if [ -n "$foreign" ]; then kill "$foreign"; wait "$foreign" 2>/dev/null || true; fi
done
}
