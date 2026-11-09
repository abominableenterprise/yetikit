#!/usr/bin/env bash
# Deadlines, ownership persistence and failed activation cleanup. Never runs Unity or touches the network.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

# --- timeout -------------------------------------------------------------------------------------------------------
reset "202 10"; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=2 -- activate
check "timeout: gives up after UNITY_SEAT_WAIT_MINUTES with a clear error, no activation" \
  '[ "$rc" != 0 ] && grep -q "no Unity seat after 2 min (UNITY_SEAT_WAIT_MINUTES)" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ]'
check "timeout: one progress line per minute" \
  '[ "$(grep -c "seat: waiting for a Unity seat" "$tmp/log")" = 2 ] && grep -q "(1 min)" "$tmp/log" && [ "$(calls acquire)" = 12 ]'
reset "202 99"; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 -- activate
check "Retry-After is capped at 10 s" '[ "$rc" != 0 ] && [ "$(sort -u "$tmp/sleeps")" = 10 ] && grep -q "no Unity seat after 1 min" "$tmp/log"'

# Slow HTTP answers count against the deadline, not just Retry-After sleeps.
reset "202 10"; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 FAKE_HTTP_SECONDS=30 -- activate
check "slow 202 replies consume the elapsed-time budget" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 2 ] && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ] && grep -q "no Unity seat after 1 min" "$tmp/log"'

reset 000; rm -f "$ULF" "$state"
lu "${hub[@]}" -- activate
check "ambiguous acquire response releases the possible hub grant" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ]'

# A directory at the destination makes atomic rename fail even as root.
reset 200; rm -f "$ULF" "$state"; mkdir "$state"; echo sentinel > "$state/keep"
lu "${hub[@]}" -- activate
check "marker persistence failure releases in-memory ownership before licensing" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ] && [ "$(cat "$state/keep")" = sentinel ] && grep -q "could not persist ownership" "$tmp/log" && [ "$(find "$OUT_DIR" -name "unity-seat.held.*" ! -name "*.lock" | wc -l)" = 0 ]'
rm -rf "$state"

# --- the licensing client fails after the seat was acquired: the trap releases it ----------------------------------
reset 200; rm -f "$ULF" "$state"
lu "${hub[@]}" FAKE_LC_FAIL=1 -- activate
check "acquire ok, licensing client fails: the EXIT trap releases the seat" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ] && grep -q "activation failed; releasing" "$tmp/log"'
reset "202 10" 200; rm -f "$ULF" "$state"
lu "${hub[@]}" -- activate
reset 200; rm -f "$ULF"
lu "${hub[@]}" FAKE_LC_FAIL=1 -- activate
check "a seat an earlier invocation acquired is not released by a later failed activation" \
  '[ "$rc" != 0 ] && [ "$(calls release)" = 0 ] && [ -f "$state" ]'
rm -f "$state"

# The APK path calls unity/activation inside a subshell; ownership stays local.
reset 000; rm -f "$ULF" "$state"
rc=0; env UNITY_USERNAME=u UNITY_PASSWORD=p "${hub[@]}" bash -c '. "$1"; (cmd_activate)' _ "$script" > "$tmp/log" 2>&1 || rc=$?
check "subshell activation owns its own failed-acquire cleanup" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ]'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
