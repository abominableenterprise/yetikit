#!/usr/bin/env bash
# Isolated synthetic licence lifecycle/idle regression cases.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-idle-fixture.sh"

rm -f "$ULF"
lu activate; lu activate
check 'two commands activate once and return zero times' '[ "$rc" = 0 ] && [ "$(count --activate-ulf)" = 1 ] && [ "$(count --return-ulf)" = 0 ]'
lu return
check 'explicit return returns/releases once' '[ "$rc" = 0 ] && [ "$(count --return-ulf)" = 1 ] && [ "$(grep -c release "$tmp/hub-calls")" = 1 ]'
lu return
check 'second return is no-op success' '[ "$rc" = 0 ] && [ "$(count --return-ulf)" = 1 ] && grep -q "return: licence already returned" "$tmp/log"'
lu activate
UNITY_RETURN_ON_EXIT=1 lu return
check 'explicit return plus EXIT opt-in returns exactly once' '[ "$rc" = 0 ] && [ "$(count --return-ulf)" = 2 ]'
# A failed explicit return must not be retried by the EXIT trap either.
lu activate
UNITY_RETURN_ON_EXIT=1 FAKE_RETURN_RC=9 lu return
check 'failed explicit return plus EXIT opt-in attempts exactly once' '[ "$rc" = 9 ] && [ "$(count --return-ulf)" = 3 ] && [ -f "$ULF" ]'
# Keep cumulative successful-return checks below independent of this deliberate failed attempt.
sed -i '$d' "$tmp/lc-calls"
lu activate
FAKE_MISSING=1 lu return
check 'client 1404 is success and releases the seat' '[ "$rc" = 0 ] && [ ! -f "$ULF" ] && [ ! -f "$OUT_DIR/unity-seat.held" ]'
lu activate
FAKE_UNITY_RC=1 lu open
check 'failed command holds licence and seat' '[ "$rc" != 0 ] && [ -f "$ULF" ] && [ -f "$OUT_DIR/unity-seat.held" ] && [ "$(count --return-ulf)" = 3 ]'
UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=1 lu open
check 'failed command with opt-in returns even a reused licence' '[ "$rc" != 0 ] && [ ! -f "$ULF" ] && [ "$(count --return-ulf)" = 4 ]'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
