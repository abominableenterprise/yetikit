#!/usr/bin/env bash
# Acquisition conflicts and HTTP failures. Never runs Unity or touches the network.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

# --- 409 race: polls just like 202, never activates without a lease -------------------------------------------------
reset "409 3" 409 200; rm -f "$ULF" "$state"
lu "${hub[@]}" 'FAKE_CONFLICT_BODY={"error":"seat acquisition race"}' -- activate
check "409 race then 200: acquires, writes this task's state, then activates" \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 3 ] && [ "$(cut -d" " -f1 "$state")" = 5455 ] && grep -q -- --activate-ulf "$tmp/lc-calls" && grep -q "seat: acquired a Unity seat" "$tmp/log" && [ "$(calls release)" = 0 ] && ! grep -qi warning "$tmp/log"'
check "409 race: sleeps Retry-After (3), then the default 2, with one progress line" \
  '[ "$(tr "\n" " " < "$tmp/sleeps")" = "3 2 " ] && [ "$(grep -c "seat: waiting for a Unity seat" "$tmp/log")" = 1 ]'
reset "409 10"; rm -f "$ULF" "$state"
lu "${hub[@]}" 'FAKE_CONFLICT_BODY={"error":"seat acquisition race"}' UNITY_SEAT_WAIT_MINUTES=1 -- activate
check "409 race timeout: fails before activation, leaves the queue, no state file" \
  '[ "$rc" != 0 ] && grep -q "no Unity seat after 1 min (UNITY_SEAT_WAIT_MINUTES)" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ] && [ "$(calls acquire)" = 6 ] && [ "$(calls release)" = 1 ] && [ "$(sort -u "$tmp/sleeps")" = 10 ] && [ "$(grep -c "seat: waiting for a Unity seat" "$tmp/log")" = 1 ]'
reset 409; rm -f "$ULF" "$state"
lu "${hub[@]}" 'FAKE_ACQUIRE_BODY={"error":"task closed"}' -- activate
check "409 task closed: fails before the licensing client, without polling" \
  '[ "$rc" != 0 ] && grep -q "HTTP 409: {\"error\":\"task closed\"}" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ] && [ ! -s "$tmp/sleeps" ]'

# --- 409: a finished task fails; other 409s retain the legacy no-lease fallback -------------------------------------
reset 409; rm -f "$ULF" "$state"
lu "${hub[@]}" FAKE_ACQUIRE_BODY= -- activate
check "409 with an empty body: warns and activates without a state file" \
  '[ "$rc" = 0 ] && grep -q "warning: seat: hub answered 409 (empty body); continuing without a lease" "$tmp/log" && grep -q -- --activate-ulf "$tmp/lc-calls" && [ ! -f "$state" ] && [ "$(calls release)" = 0 ]'
reset 409; rm -f "$ULF" "$state"
lu "${hub[@]}" "FAKE_ACQUIRE_BODY={\"error\":\"legacy conflict $token $(printf 'x%.0s' $(seq 200))\"}" -- activate
check "409 with another body: warns with at most 120 chars of it, never the token" \
  '[ "$rc" = 0 ] && grep -q "hub answered 409 ({\"error\":\"legacy conflict <token> x" "$tmp/log" && no_token && [ ! -f "$state" ] && [ "$(grep "hub answered 409" "$tmp/log" | sed "s/.*409 (\(.*\)); continuing.*/\1/" | wc -c)" -le 121 ]'
reset 409; rm -f "$ULF" "$state"
lu "${hub[@]}" 'FAKE_ACQUIRE_BODY={"error":"task 5455 was Cancelled"}' -- activate
check "409 with a cancelled body: activate fails before the licensing client runs" \
  '[ "$rc" != 0 ] && grep -q "HTTP 409" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ] && no_token'
for word in "done" closed finished; do
  reset 409; rm -f "$ULF" "$state"
  lu "${hub[@]}" "FAKE_ACQUIRE_BODY={\"error\":\"task is $word\"}" -- activate
  check "409 with a \"$word\" body: fails before the licensing client runs" '[ "$rc" != 0 ] && [ ! -s "$tmp/lc-calls" ]'
done

# --- other codes: activate fails before the licensing client -------------------------------------------------------
reset 500; rm -f "$ULF" "$state"
lu "${hub[@]}" -- activate
check "acquire HTTP 500: activate fails before the licensing client runs" \
  '[ "$rc" != 0 ] && grep -q "HTTP 500" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ] && no_token'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
