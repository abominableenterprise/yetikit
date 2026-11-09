#!/usr/bin/env bash
# Return, missing credentials and unleased responses. Never runs Unity or touches the network.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

reset 200; printf '5455 1\n' > "$state"
# --- return: exactly one release, state file gone ------------------------------------------------------------------
reset 200
lu "${hub[@]}" -- return
check "successful return: exactly one release and the state file is gone" \
  '[ "$rc" = 0 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ] && [ ! -f "$ULF" ] && grep -q -- --return-ulf "$tmp/lc-calls" && no_token'
reset 200; echo "5455 1" > "$state"
lu "${hub[@]}" 'FAKE_RELEASE_BODY={"status":"not_leased"}' -- return
check "release 200 not_leased: succeeds without warning and removes the state file" \
  '[ "$rc" = 0 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ] && [ ! -s "$tmp/lc-calls" ] && grep -Fq "return: licence already returned" "$tmp/log" && ! grep -qi warning "$tmp/log"'
reset 200; good_ulf_now() { printf '%s\n' "$good_ulf" > "$ULF"; }; good_ulf_now; echo "5455 1" > "$state"
lu "${hub[@]}" FAKE_RETURN_RC=5 -- return
check "failed return: no release, seat still held" '[ "$rc" = 5 ] && [ "$(calls release)" = 0 ] && [ -f "$state" ] && [ -f "$ULF" ]'
reset 200
lu "${hub[@]}" FAKE_RELEASE_CODE=500 -- return
check "failed release only warns" '[ "$rc" = 0 ] && grep -q "warning: seat release failed (HTTP 500)" "$tmp/log" && [ ! -f "$state" ]'
reset 200
lu "${hub[@]}" -- return
check "return without ULF or state: no Licensing Client or release call" \
  '[ "$rc" = 0 ] && [ ! -s "$tmp/curl-calls" ] && [ ! -s "$tmp/lc-calls" ] && grep -Fq "return: licence already returned" "$tmp/log"'

# --- no Unity credentials: the seat is skipped entirely ---------------------------------------------------------------
reset 200; rm -f "$ULF" "$state"
rc=0; env "${hub[@]}" bash "$script" activate > "$tmp/log" 2>&1 || rc=$?
check "no Unity creds in a hub task: activate fails before seat or Licensing Client work" \
  '[ "$rc" != 0 ] && [ ! -s "$tmp/curl-calls" ] && [ ! -s "$tmp/lc-calls" ] && grep -Fxq "[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)" "$tmp/log" && ! grep -q "seat:" "$tmp/log"'
reset 200; echo "5455 1" > "$state"
env "${hub[@]}" bash -c '. "$1"; seat_acquire; seat_release; seat_acquire' _ "$script" > "$tmp/log" 2>&1 || true
check "no Unity creds: seat_acquire and seat_release make no curl call (skip logged once)" \
  '[ ! -s "$tmp/curl-calls" ] && [ "$(grep -c "seat: no Unity credentials, skipping" "$tmp/log")" = 1 ]'
rm -f "$state"
reset 200
env "${hub[@]}" USERNAME=u PASSWORD=p bash -c '. "$1"; creds_fallback; seat_acquire' _ "$script" > "$tmp/log" 2>&1 || true
check "creds from the USERNAME/PASSWORD fallback count: the seat is acquired" '[ "$(calls acquire)" = 1 ] && [ -f "$state" ]'
rm -f "$state"

# --- 200 not_leased: activate without a lease ----------------------------------------------------------------------
reset 200; rm -f "$ULF" "$state"
lu "${hub[@]}" 'FAKE_ACQUIRE_BODY={"status":"not_leased"}' -- activate
check "200 not_leased: activates without a state file" \
  '[ "$rc" = 0 ] && grep -q "seat: task is not seat-leased; continuing without a lease" "$tmp/log" && grep -q -- --activate-ulf "$tmp/lc-calls" && [ ! -f "$state" ]'
reset 200
lu "${hub[@]}" -- return
check "200 not_leased: return makes no release call" '[ "$rc" = 0 ] && [ "$(calls release)" = 0 ]'
reset 200; rm -f "$ULF" "$state"
lu "${hub[@]}" 'FAKE_ACQUIRE_BODY={"status":"queued"}' -- activate
check "200 without acquired/not_leased: fails before the licensing client runs" \
  '[ "$rc" != 0 ] && grep -q "without \"acquired\"" "$tmp/log" && [ ! -s "$tmp/lc-calls" ]'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
