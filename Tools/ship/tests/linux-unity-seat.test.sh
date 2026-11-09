#!/usr/bin/env bash
# Acquisition, polling and held-seat reuse. Never runs Unity or touches the network.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

# --- no hub env: no curl call, activate proceeds -------------------------------------------------------------------
reset 200; rm -f "$ULF" "$state"
lu -- activate
check "no hub env: activate proceeds without calling the hub" \
  '[ "$rc" = 0 ] && [ ! -s "$tmp/curl-calls" ] && grep -q -- --activate-ulf "$tmp/lc-calls" && [ ! -f "$state" ]'
check "no hub env: logs the skip" '[ "$(grep -c "seat: no hub task env, skipping" "$tmp/log")" = 1 ]'
check "no hub env: a second seat_acquire in the same run logs nothing more" \
  '[ "$(UNITY_USERNAME=u UNITY_PASSWORD=p bash -c ". \"\$1\"; seat_acquire; seat_acquire" _ "$script" 2>&1 | grep -c "no hub task env")" = 1 ]'

# --- 202, 202, 200: polls, then acquires and activates ------------------------------------------------------------
reset "202 3" "202" 200; rm -f "$ULF" "$state"
lu "${hub[@]}" -- activate
check "202, 202, 200: acquires after polling, then activates" \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 3 ] && grep -q -- --activate-ulf "$tmp/lc-calls" && [ -f "$state" ]'
check "202: sleeps Retry-After (3), then the default 2" '[ "$(tr "\n" " " < "$tmp/sleeps")" = "3 2 " ]'
check "acquire posts to <hub>/tasks/<id>/seat" 'grep -qx "acquire hub-origin/tasks/5455/seat" "$tmp/curl-calls"'
check "the seat is acquired before the licensing client runs" 'grep -q "acquired a Unity seat" "$tmp/log" && ! grep -q "^release" "$tmp/curl-calls"'
check "the token never appears in output nor on curl's command line" \
  'no_token && ! grep "^args:" "$tmp/curl-argv" | grep -q "$token" && grep -q "Bearer $token" "$tmp/curl-argv"'

# --- state file present: no second acquire (activate, re-activation) ----------------------------------------------
reset 200; rm -f "$ULF"
lu "${hub[@]}" -- activate
check "second activate with the seat held: no second acquire" '[ "$rc" = 0 ] && [ "$(calls acquire)" = 0 ] && grep -q -- --activate-ulf "$tmp/lc-calls"'
reset 200; rm -f "$ULF"
lu "${hub[@]}" -- open
check "re-activation (ULF vanished) with the seat held: no second acquire" \
  '[ "$rc" = 0 ] && grep -q "re-activating once" "$tmp/log" && [ "$(calls acquire)" = 0 ]'
reset 200; rm -f "$ULF" "$state"
lu "${hub[@]}" -- open
check "re-activation (ULF vanished) without the seat: acquires first" \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 1 ] && [ -f "$state" ] && [ "$(calls release)" = 0 ]'

# --- open fails after a successful activate: the seat stays held ---------------------------------------------------
reset 200
lu "${hub[@]}" FAKE_UNITY_RC=1 -- open
check "open fails with a licence active: NO release, seat still held" '[ "$rc" != 0 ] && [ "$(calls release)" = 0 ] && [ -f "$state" ]'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
