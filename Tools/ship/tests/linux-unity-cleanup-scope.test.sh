#!/usr/bin/env bash
# Cleanup may signal only this run's editors, never a foreign editor or its shm.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/fixture.sh"
tmp="$(mktemp -d)"
pids=()
finish() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
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
export LINUX_UNITY_RUN="$$:$(proc_start "$$")"
failures=0
check() {
  if "$@"; then echo "PASS: $1"; else echo "FAIL: $1" >&2; failures=$((failures + 1)); fi
}
fixtures() {
  touch "$SHM_DIR/udsMem-fixture" "$SHM_DIR/sem.udsMem-fixture" "$PROJECT/Temp/UnityLockfile"
}
fixtures_present() {
  [ -f "$SHM_DIR/udsMem-fixture" ] && [ -f "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ -f "$PROJECT/Temp/UnityLockfile" ]
}
fixtures_absent() {
  [ ! -f "$SHM_DIR/udsMem-fixture" ] && [ ! -f "$SHM_DIR/sem.udsMem-fixture" ] &&
    [ ! -f "$PROJECT/Temp/UnityLockfile" ]
}
editor_ready() { [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$UNITY_BIN" ]; }

# No inherited marker: simulate an editor opened outside the runner.
env -u LINUX_UNITY_RUN "$UNITY_BIN" 120 & unmarked=$!; pids+=("$unmarked")
export SHIP_FIXTURE_PIDS="${pids[*]}"
ship_wait_until editor_ready "$unmarked"
fixtures
cleanup_unity 2> "$tmp/unmarked.log"
unmarked_survives() {
  kill -0 "$unmarked" 2>/dev/null && fixtures_present &&
    [ "$(grep -c '^\[linux-unity\]' "$tmp/unmarked.log")" = 1 ] && grep -w "$unmarked" "$tmp/unmarked.log"
}
check unmarked_survives
kill "$unmarked" 2>/dev/null || true; wait "$unmarked" 2>/dev/null || true

# A different live run's marker confers no ownership on this cleanup.
env -u LINUX_UNITY_RUN /usr/bin/sleep 120 & peer=$!; pids+=("$peer")
peer_marker="$peer:$(proc_start "$peer")"
env LINUX_UNITY_RUN="$peer_marker" "$UNITY_BIN" 120 & foreign=$!; pids+=("$foreign")
export SHIP_FIXTURE_PIDS="${pids[*]}"
ship_wait_until editor_ready "$foreign"
# Own editor helpers must still be killed even when a foreign editor blocks wiping.
"$UNITY_BIN" 120 & owned=$!; pids+=("$owned")
export SHIP_FIXTURE_PIDS="${pids[*]}"
ship_wait_until editor_ready "$owned"
fixtures
cleanup_unity 2> "$tmp/foreign.log"
other_live_run_survives() {
  kill -0 "$peer" && kill -0 "$foreign" 2>/dev/null && ! kill -0 "$owned" 2>/dev/null &&
    fixtures_present && [ "$(grep -c '^\[linux-unity\]' "$tmp/foreign.log")" = 1 ] && grep -w "$foreign" "$tmp/foreign.log"
}
check other_live_run_survives
wait "$owned" 2>/dev/null || true
kill "$foreign" 2>/dev/null || true; wait "$foreign" 2>/dev/null || true

# Once no foreign editor remains, kill own editors and wipe all three fixtures.
"$UNITY_BIN" 120 & owned=$!; pids+=("$owned")
export SHIP_FIXTURE_PIDS="${pids[*]}"
ship_wait_until editor_ready "$owned"
/usr/bin/sleep 120 & helper=$!; pids+=("$helper")
fixtures
cleanup_unity
own_editor_only_and_wipe() {
  ! kill -0 "$owned" 2>/dev/null && kill -0 "$helper" && fixtures_absent
}
check own_editor_only_and_wipe
wait "$owned" 2>/dev/null || true

[ "$failures" = 0 ]
