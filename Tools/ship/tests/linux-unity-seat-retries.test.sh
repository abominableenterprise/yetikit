#!/usr/bin/env bash
# Transient hub failures and recovery using fake curl and a monotonic test clock.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

reset 502 200; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 -- activate
check '502 then 200 acquires the seat and activates' \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 2 ] && [ -f "$state" ] && grep -q -- --activate-ulf "$tmp/lc-calls" && [ "$(calls release)" = 0 ]'
check '502 logs just one transient retry' \
  '[ "$(grep -c "HTTP 502.*retrying in 2 s" "$tmp/log")" = 1 ] && no_token'

reset 503; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 -- activate
check 'repeated 503 backs off, caps the delay, and stops exactly at the deadline' \
  '[ "$rc" != 0 ] && [ "$(cat "$tmp/clock")" = 60 ] && [ "$(tr "\n" " " < "$tmp/sleeps")" = "2 4 8 10 10 10 10 6 " ] && [ "$(calls acquire)" = 8 ] && [ "$(grep -c "HTTP 503.*retrying" "$tmp/log")" = 7 ]'
check '503 timeout says why, never activates, and releases on exit' \
  'grep -q "no Unity seat after 1 min (UNITY_SEAT_WAIT_MINUTES)" "$tmp/log" && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ] && no_token'

reset 503; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 FAKE_HTTP_SECONDS=30 -- activate
check 'the next curl request is also capped by the remaining budget' \
  '[ "$rc" != 0 ] && [ "$(cat "$tmp/clock")" = 60 ] && [ "$(calls acquire)" = 2 ] && grep -q "no Unity seat after 1 min" "$tmp/log"'

reset 403; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 -- activate
check '403 fails immediately without sleeping or activating' \
  '[ "$rc" != 0 ] && grep -q "acquire failed (HTTP 403)" "$tmp/log" && [ "$(calls acquire)" = 1 ] && [ ! -s "$tmp/sleeps" ] && [ ! -s "$tmp/lc-calls" ] && [ ! -f "$state" ] && no_token'

reset network-error 200; rm -f "$ULF" "$state"
lu "${hub[@]}" UNITY_SEAT_WAIT_MINUTES=1 -- activate
check 'nonzero curl exit retries once without leaking the token, then acquires' \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 2 ] && [ -f "$state" ] && [ "$(grep -c "network error.*retrying in 2 s" "$tmp/log")" = 1 ] && no_token'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
