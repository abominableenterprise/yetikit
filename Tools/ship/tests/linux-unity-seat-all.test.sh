#!/usr/bin/env bash
# Default and opt-in licence lifetime for all/open. Never runs Unity or touches the network.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

# --- all holds its licence by default; explicit opt-in retains the legacy return behavior -------------------------
reset 200; rm -f "$ULF" "$state"
lu "${hub[@]}" -- all
check "all by default: acquires and keeps the licence and seat" \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 0 ] && [ -f "$ULF" ] && [ -f "$state" ] && ! grep -q -- --return-ulf "$tmp/lc-calls"'
reset 200
lu "${hub[@]}" FAKE_UNITY_RC=1 -- all
check "all by default: a failed run keeps its reused licence and seat" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 0 ] && [ "$(calls release)" = 0 ] && [ -f "$ULF" ] && [ -f "$state" ] && [ ! -s "$tmp/lc-calls" ]'
reset 200
lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 -- open
check "UNITY_RETURN_ON_EXIT=1: a reused licence returns and releases its existing seat" \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 0 ] && [ "$(calls release)" = 1 ] && [ ! -f "$ULF" ] && [ ! -f "$state" ] && grep -q -- --return-ulf "$tmp/lc-calls" && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
reset 200; rm -f "$ULF"
lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 -- all
check "all with UNITY_RETURN_ON_EXIT=1: acquires before activation and releases after the return" \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ]'
reset 200; rm -f "$ULF"
lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=1 -- all
check "all with UNITY_RETURN_ON_EXIT=1: a failed run still returns and releases" '[ "$rc" != 0 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ]'
reset 200; rm -f "$ULF"
lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_LC_FAIL=1 FAKE_RETURN_RC=7 -- all
check "all with UNITY_RETURN_ON_EXIT=1: failed activation releases the seat without a spurious return" \
  '[ "$rc" != 0 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ] && ! grep -q -- --return-ulf "$tmp/lc-calls"'
reset 200; rm -f "$ULF"
lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=1 -- open
check "UNITY_RETURN_ON_EXIT=1: the exit return releases the seat (once)" \
  '[ "$rc" != 0 ] && grep -q -- --return-ulf "$tmp/lc-calls" && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ]'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
