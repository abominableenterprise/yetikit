#!/usr/bin/env bash
# A wrapper-only SIGKILL leaves the inherited cleanup flock with its fake editor.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-stop-fixture.sh"

SHIP_READINESS_RUN="$tmp" FAKE_SLEEP=300 bash "$script" open >"$tmp/run.log" 2>&1 &
readiness_runner=$!; runner=$readiness_runner
editor="$(ship_wait_for_pid "$tmp/unity.pid")"
lock="$tmp/shm/.linux-unity-cleanup.lock"
kill -KILL "$runner"; wait "$runner" 2>/dev/null || true
check "the orphan still holds the cleanup flock" 'alive "$editor" && ! flock -n "$lock" true'
rc=0; bash "$script" open >"$tmp/contender.log" 2>&1 || rc=$?
check "the lock diagnostic points to stop and preserves the pidfile" \
  '[ "$rc" != 0 ] && grep -q "stop its checkout" "$tmp/contender.log" && [ -f "$OUT_DIR/linux-unity.pid" ]'

for cmd in setup cache-save cache-restore; do
  rc=0; bash "$script" "$cmd" >"$tmp/contender.log" 2>&1 || rc=$?
  check "$cmd refuses overlap and preserves the orphan record" \
    '[ "$rc" != 0 ] && grep -q "stop" "$tmp/contender.log" && read -r owner _ < "$OUT_DIR/linux-unity.pid" && [ "$owner" = "$runner" ]'
done

rc=0; bash "$script" stop >"$tmp/stop.log" 2>&1 || rc=$?
check "stop drains the marked editor despite the dead wrapper" '[ "$rc" = 0 ] && ! alive "$editor"'
check "the orphan pidfile is removed and the same flock can be acquired again" \
  '[ ! -f "$OUT_DIR/linux-unity.pid" ] && flock -n "$lock" true'
check "a fresh editor run can start" 'bash "$script" open >"$tmp/fresh.log" 2>&1'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
