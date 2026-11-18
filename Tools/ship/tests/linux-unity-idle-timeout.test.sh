#!/usr/bin/env bash
# Isolated synthetic licence lifecycle/idle regression cases.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-idle-fixture.sh"

# Start without a licence, as after the opt-in return lifecycle case.
rm -f "$ULF"
# Bound both a TERM-resistant client and a TERM-exiting client whose child alone ignores TERM.
# Outer deadlines include validated config loading as well as the client's
# 1 s timeout + 5 s KILL grace. The 1 s production limit stays unchanged.
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d" " -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
for hang in 1 child-only; do
rm -f "$tmp/return.pid" "$tmp/return-child.pid"
lu activate
UNITY_IDLE_RETURN_MINUTES=0 UNITY_RETURN_TIMEOUT=1 FAKE_RETURN_HANG="$hang" \
  timeout -k 1 30 bash "$script" __idle-return > "$tmp/hung-watch-log" 2>&1 & hung_watcher=$!
child="$(ship_wait_for_pid "$tmp/return-child.pid")"
client="$(ship_read_pid "$tmp/return.pid")"  # published before the child is forked
rc=0; timeout -k 1 20 bash "$script" stop > "$tmp/stop-log" 2>&1 || rc=$?
wait "$hung_watcher" 2>/dev/null || true
check "idle return ($hang): timeout unblocks stop without deleting licence or releasing seat" \
  '[ "$rc" = 0 ] && grep -q "idle return failed" "$tmp/hung-watch-log" && [ -f "$ULF" ] && [ -f "$OUT_DIR/unity-seat.held" ]'
check "idle return ($hang): client and TERM-resistant child are killed" \
  '! alive "$client" && ! alive "$child"'
# Clean up even on the failing-first run, where the outer deadline killed the watcher, not the client.
kill -KILL "$client" "$child" 2>/dev/null || true
rc=0; timeout -k 1 20 bash "$script" return > "$tmp/retry-log" 2>&1 || rc=$?
check "idle return ($hang): explicit retry succeeds after timeout and releases seat" \
  '[ "$rc" = 0 ] && [ ! -f "$ULF" ] && [ ! -f "$OUT_DIR/unity-seat.held" ]'
done

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
