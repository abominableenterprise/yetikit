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

# Inject unlink failures at just the two paths; stdout/stderr and all other
# filesystem operations still use the real wrapper and fixture files.
cat > "$tmp/bin/rm" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FAIL_UNLINK:-}" ] && [ "$arg" = "$FAIL_UNLINK" ]; then
    echo 'synthetic unlink failure' >&2
    exit 1
  fi
done
exec /bin/rm "$@"
EOF
chmod +x "$tmp/bin/rm"

reset 200; good_ulf_now; echo "5455 1" > "$state"
lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 "FAIL_UNLINK=$ULF" -- open
check 'exit return fails if the returned ULF remains and does not release the seat' \
  '[ "$rc" != 0 ] && [ -f "$ULF" ] && [ -f "$state" ] && [ "$(calls release)" = 0 ] && grep -qx -- --return-ulf "$tmp/lc-calls"'
: > "$tmp/runs"; : > "$tmp/lc-calls"
lu "${hub[@]}" "FAIL_UNLINK=$ULF" -- open
check 'a subsequent run cannot use or replace the returned ULF' \
  '[ "$rc" != 0 ] && [ ! -s "$tmp/runs" ] && [ ! -s "$tmp/lc-calls" ] && grep -q "licence return is pending" "$tmp/log"'
ln -s "$ULF" "$tmp/alias.ulf"
lu "${hub[@]}" "ULF=$tmp/alias.ulf" -- activate
check 'explicit activation through a symlink also rejects a ULF pending return cleanup' \
  '[ "$rc" != 0 ] && [ ! -s "$tmp/lc-calls" ] && grep -q "licence return is pending" "$tmp/log"'
lu "${hub[@]}" FAKE_RETURN_RC=5 -- return
check 'retry removes the confirmed returned ULF and releases the seat without calling the client again' \
  '[ "$rc" = 0 ] && [ ! -f "$ULF" ] && [ ! -f "$state" ] && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ]'
lu "${hub[@]}" -- activate
check 'activation after cleanup acquires a new seat' \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 1 ] && [ -f "$state" ] && [ -f "$ULF" ]'

reset 200; good_ulf_now; echo "5455 1" > "$state"
lu "${hub[@]}" "FAIL_UNLINK=$state" -- return
check 'seat marker unlink failure prevents the hub release and fails the return' \
  '[ "$rc" != 0 ] && [ "$(calls release)" = 0 ] && [ -f "$state" ] && [ ! -f "$ULF" ] && grep -q "could not clear ownership" "$tmp/log"'
lu "${hub[@]}" -- return
check 'retry without a ULF clears the seat marker and releases once' \
  '[ "$rc" = 0 ] && [ "$(calls release)" = 1 ] && [ ! -f "$state" ] && [ "$(grep -c -- --return-ulf "$tmp/lc-calls")" = 1 ]'
lu "${hub[@]}" -- activate
check 'activation after the successful hub release must acquire a seat' \
  '[ "$rc" = 0 ] && [ "$(calls acquire)" = 1 ] && [ -f "$state" ] && [ -f "$ULF" ]'

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
