#!/usr/bin/env bash
# Tests linux-unity.sh's per-run Unity seat lease (Tools/ship/linux-unity-seat.sh) with a fake curl (canned hub
# answers), a fake sleep, the fake editor and a fake Licensing Client; never runs Unity or touches the network.
# Run: Tools/ship/test-all.sh
# shellcheck disable=SC2016,SC2034 # check() evals its single-quoted condition, which reads rc
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"
# Concurrent commands run under timeout (including their children). Open gates on
# early exit too, then terminate/reap the bounded supervisors before removing files.
concurrent=()
cleanup() {
  touch "$tmp/lc-unblock" "$tmp/release-unblock"
  local pid
  for pid in "${concurrent[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${concurrent[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Assets"; echo x > "$proj/Assets/a.txt"
# shellcheck source=Tools/ship/tests/lib/fake-unity.sh
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
git_init
good_ulf="$(cat "$ULF")"
# Fake Licensing Client: logs its first argument; --activate-ulf writes a valid ULF unless FAKE_LC_FAIL=1 (then it
# fails without one); --return-ulf exits $FAKE_RETURN_RC.
lcdir="$tmp/unity/Editor/Data/Resources/Licensing/Client"; mkdir -p "$lcdir"
cat > "$lcdir/Unity.Licensing.Client" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$tmp/lc-calls"
case "\$1" in
  --activate-ulf) [ "\${FAKE_LC_FAIL:-0}" = 1 ] && { echo "activation failed"; exit 1; }
    if [ "\${FAKE_LC_BLOCK:-0}" = 1 ]; then
      echo started > "$tmp/lc-blocked"
      while [ ! -f "$tmp/lc-unblock" ]; do /bin/sleep 0.02; done
      [ "\${FAKE_LC_BLOCK_FAIL:-1}" = 0 ] || exit 1
    fi
    printf '%s\n' '$good_ulf' > "\$ULF" ;;
  --return-ulf) exit "\${FAKE_RETURN_RC:-0}" ;;
esac
EOF
# Fake curl: logs "<action> <url>" (and its arguments and stdin, for the token check) and answers with the next line
# of $tmp/answers ("<code> [retry-after]"; the last line repeats). 200 bodies say {"status":"acquired"}; an acquire
# answers with the body in $FAKE_ACQUIRE_BODY instead when that is set ("" for an empty body).
# FAKE_CONFLICT_BODY overrides only 409 bodies; FAKE_RELEASE_BODY overrides release bodies.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
hdr="" body="" data="" url=""
echo "args: $*" >> "$FAKE_TMP/curl-argv"; cat >> "$FAKE_TMP/curl-argv"
while [ $# -gt 0 ]; do
  case "$1" in -D) hdr="$2"; shift ;; -o) body="$2"; shift ;; -d) data="$2"; shift ;; -H|-X|-w|--max-time) shift ;;
    -*) ;; *) url="$1" ;; esac; shift
done
action="$(sed 's/.*"action":"\([a-z]*\)".*/\1/' <<< "$data")"
echo "$action $url" >> "$FAKE_TMP/curl-calls"
if [ "$action" = release ] && [ "${FAKE_RELEASE_BLOCK:-0}" = 1 ]; then
  touch "$FAKE_TMP/release-blocked"
  while [ ! -f "$FAKE_TMP/release-unblock" ]; do /bin/sleep 0.02; done
fi
if [ "$action" = acquire ] && [ -n "${FAKE_HTTP_SECONDS:-}" ]; then
  echo "$(($(cat "$FAKE_TMP/clock") + FAKE_HTTP_SECONDS))" > "$FAKE_TMP/clock"
fi
n="$(grep -c "^acquire " "$FAKE_TMP/curl-calls")"
if [ "$action" = acquire ]; then line="$(sed -n "${n}p" "$FAKE_TMP/answers")"; [ -n "$line" ] || line="$(tail -n1 "$FAKE_TMP/answers")"
else line="${FAKE_RELEASE_CODE:-200}"; fi
read -r code retry <<< "$line"
{ printf 'HTTP/1.1 %s X\r\n' "$code"; [ -z "${retry:-}" ] || printf 'Retry-After: %s\r\n' "$retry"; } > "$hdr"
if [ "$action" = release ] && [ -n "${FAKE_RELEASE_BODY+x}" ]; then printf '%s' "$FAKE_RELEASE_BODY"
elif [ "$action" = acquire ] && [ -n "${FAKE_ACQUIRE_BODY+x}" ]; then printf '%s' "$FAKE_ACQUIRE_BODY"
elif [ "$code" = 409 ] && [ -n "${FAKE_CONFLICT_BODY+x}" ]; then printf '%s' "$FAKE_CONFLICT_BODY"
else case "$code" in 200) echo '{"status":"acquired"}' ;; 202) echo '{"status":"waiting","resource":"Unity"}' ;; *) echo '{}' ;; esac; fi > "$body"
printf '%s' "$code"
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE_TMP/sleeps"
echo "$(($(cat "$FAKE_TMP/clock") + $1))" > "$FAKE_TMP/clock"
EOF
# Replace only the monotonic clock, not date (ULF validation still uses real dates).
cat > "$tmp/bin/awk" <<'EOF'
#!/bin/sh
if [ "$*" = '{print int($1)} /proc/uptime' ]; then cat "$FAKE_TMP/clock"
else exec /usr/bin/awk "$@"; fi
EOF
# Report actual contention, not merely that the second command was launched.
# Activity locks use fd 9; the activation lock uses a dynamically allocated fd.
cat > "$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_LOCK_WAIT:-}" ] && [ "${1:-}" = -x ] && [ "${2:-}" != 9 ]; then
  /usr/bin/flock -n "${!#}" && exit 0
  touch "$FAKE_LOCK_WAIT"
fi
exec /usr/bin/flock "$@"
EOF
for c in crane dpkg ldd; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; done
: > "$tmp/unity/.install-complete"   # a finished install, so `all`'s setup trusts it
chmod +x "$lcdir/Unity.Licensing.Client" "$tmp/bin/"*
export BIN_DIR="$tmp/bin"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT UNITY_SEAT_WAIT_MINUTES SEAT_STATE \
  UNITY_USERNAME UNITY_PASSWORD USERNAME PASSWORD FAKE_ACQUIRE_BODY FAKE_CONFLICT_BODY FAKE_RELEASE_BODY
token="tok-SECRET-1234"
hub=(THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=5455 "THEROBOTS_TASK_TOKEN=$token")
state="$OUT_DIR/unity-seat.held"
# Run linux-unity.sh with the given env and arguments (after --); output in $tmp/log, exit code in $rc.
lu() {
  local env=(UNITY_USERNAME=u UNITY_PASSWORD=p); while [ "$1" != -- ]; do env+=("$1"); shift; done; shift
  rc=0; env "${env[@]}" bash "$script" "$@" > "$tmp/log" 2>&1 || rc=$?
}
reset() { echo 0 > "$tmp/clock"; : > "$tmp/curl-calls"; : > "$tmp/curl-argv"; : > "$tmp/lc-calls"; : > "$tmp/sleeps"; : > "$tmp/runs"; printf '%s\n' "$@" > "$tmp/answers"; }
calls() { grep -c "^$1 " "$tmp/curl-calls" || true; }
no_token() { ! grep -q "$token" "$tmp/log"; }

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

# Distinct output directories must not split the lock for the same HOME/ULF.
# Gate the first client AND its failure cleanup; wait for observed flock contention
# instead of assuming that a sleeping second command has reached the lock.
wait_file() {
  ship_wait_until test -e "$1"
}
shared_home="$tmp/shared-home"; mkdir -p "$shared_home"
first_out="$tmp/first-out"; second_out="$tmp/second-out"
reset 200; rm -f "$ULF" "$state" "$tmp/lc-blocked" "$tmp/lc-unblock" \
  "$tmp/release-blocked" "$tmp/release-unblock" "$tmp/lock-waiting"
timeout -k 5 180 env HOME="$shared_home" OUT_DIR="$first_out" UNITY_USERNAME=u UNITY_PASSWORD=p \
  "${hub[@]}" FAKE_LC_BLOCK=1 FAKE_RELEASE_BLOCK=1 bash "$script" activate > "$tmp/first-log" 2>&1 & first=$!
concurrent=("$first")
started=0; wait_file "$tmp/lc-blocked" && started=1
check "distinct OUT_DIR activations: first client reaches its gate" '[ "$started" = 1 ]'
timeout -k 5 180 env HOME="$shared_home" OUT_DIR="$second_out" UNITY_USERNAME=u UNITY_PASSWORD=p \
  "${hub[@]}" FAKE_LOCK_WAIT="$tmp/lock-waiting" bash "$script" activate > "$tmp/second-log" 2>&1 & second=$!
concurrent+=("$second")
blocked=0; wait_file "$tmp/lock-waiting" && blocked=1
check "distinct OUT_DIR activations: second blocks before hub or licensing work" \
  '[ "$blocked" = 1 ] && [ "$(calls acquire)" = 1 ] && [ "$(grep -c -- --activate-ulf "$tmp/lc-calls")" = 1 ] && kill -0 "$second"'
touch "$tmp/lc-unblock"
releasing=0; wait_file "$tmp/release-blocked" && releasing=1
check "distinct OUT_DIR activations: lock covers the failed activation's hub release" \
  '[ "$releasing" = 1 ] && [ "$(calls acquire)" = 1 ] && [ "$(grep -c -- --activate-ulf "$tmp/lc-calls")" = 1 ] && kill -0 "$second"'
touch "$tmp/release-unblock"
first_rc=0; wait "$first" || first_rc=$?
second_rc=0; wait "$second" || second_rc=$?
concurrent=()
check "distinct OUT_DIR activations: release precedes reacquire and the new seat stays held" \
  '[ "$first_rc" = 1 ] && [ "$second_rc" = 0 ] && [ "$(cut -d" " -f1 "$tmp/curl-calls" | tr "\\n" " ")" = "acquire release acquire " ] && [ ! -f "$first_out/unity-seat.held" ] && [ -f "$second_out/unity-seat.held" ] && [ -f "$ULF" ]'
rm -f "$ULF" "$second_out/unity-seat.held"

# No hub here: exercise licence serialization independently of task-local markers.
# Return starts while activation has not yet written the shared ULF; it must wait
# and then return that licence, not report "already returned" and leave it active.
reset 200; rm -f "$tmp/lc-blocked" "$tmp/lc-unblock" "$tmp/lock-waiting"
timeout -k 5 180 env HOME="$shared_home" OUT_DIR="$first_out" UNITY_USERNAME=u UNITY_PASSWORD=p \
  FAKE_LC_BLOCK=1 FAKE_LC_BLOCK_FAIL=0 bash "$script" activate > "$tmp/first-log" 2>&1 & first=$!
concurrent=("$first")
started=0; wait_file "$tmp/lc-blocked" && started=1
check "distinct OUT_DIR activation/return: activation reaches its gate" '[ "$started" = 1 ]'
timeout -k 5 180 env HOME="$shared_home" OUT_DIR="$second_out" UNITY_USERNAME=u UNITY_PASSWORD=p \
  FAKE_LOCK_WAIT="$tmp/lock-waiting" bash "$script" return > "$tmp/second-log" 2>&1 & second=$!
concurrent+=("$second")
blocked=0; wait_file "$tmp/lock-waiting" && blocked=1
check "distinct OUT_DIR activation/return: return blocks before checking the absent ULF" \
  '[ "$blocked" = 1 ] && [ ! -f "$ULF" ] && ! grep -q -- --return-ulf "$tmp/lc-calls" && kill -0 "$second"'
touch "$tmp/lc-unblock"
first_rc=0; wait "$first" || first_rc=$?
second_rc=0; wait "$second" || second_rc=$?
concurrent=()
check "distinct OUT_DIR activation/return: return runs after activation and removes the ULF" \
  '[ "$first_rc" = 0 ] && [ "$second_rc" = 0 ] && [ ! -f "$ULF" ] && [ "$(grep -E -- "--(activate|return)-ulf" "$tmp/lc-calls" | tr "\\n" " ")" = "--activate-ulf --return-ulf " ] && [ ! -s "$tmp/curl-calls" ]'

# The APK path calls unity/activation inside a subshell; ownership stays local.
reset 000; rm -f "$ULF" "$state"
rc=0; env UNITY_USERNAME=u UNITY_PASSWORD=p "${hub[@]}" bash -c '. "$1"; (cmd_activate)' _ "$script" > "$tmp/log" 2>&1 || rc=$?
check "subshell activation owns its own failed-acquire cleanup" \
  '[ "$rc" != 0 ] && [ "$(calls acquire)" = 1 ] && [ "$(calls release)" = 1 ] && [ ! -s "$tmp/lc-calls" ]'

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

# --- TERM during the activation: the trap runs ------------------------------------------------------------------------
reset 200; rm -f "$ULF" "$state"
printf '#!/bin/sh\necho "$1" >> "%s/lc-calls"\n[ "$1" != --activate-ulf ] || { echo $$ > "%s/lc-started"; exec /bin/sleep 300; }\n' "$tmp" "$tmp" > "$lcdir/Unity.Licensing.Client"
env UNITY_USERNAME=u UNITY_PASSWORD=p "${hub[@]}" bash "$script" activate > "$tmp/log" 2>&1 & runner=$!
ship_wait_until test -s "$tmp/lc-started"
kill -TERM "$runner"
# Completion is bounded well below the client's 300 s lifetime, not a 2 s scheduler race.
runner_exited() { ! kill -0 "$runner" 2>/dev/null; }
prompt=1
if ! ship_wait_until runner_exited; then prompt=0; kill "$(cat "$tmp/lc-started")" 2>/dev/null || true; fi
rc=0; wait "$runner" 2>/dev/null || rc=$?
check "wrapper-only TERM stops and reaps the client before releasing the seat" \
  '[ "$prompt" = 1 ] && [ "$rc" = 143 ] && ! kill -0 "$(cat "$tmp/lc-started")" 2>/dev/null && [ "$(calls release)" = 1 ] && [ ! -f "$state" ] && no_token'

# A client may finish activation while handling TERM. Wait for it, then keep the valid licence/seat.
reset 200; rm -f "$ULF" "$state" "$tmp/lc-started"
cat > "$lcdir/Unity.Licensing.Client" <<'EOF'
#!/usr/bin/env bash
trap 'echo "<root><License/><Signature>x</Signature></root>" > "$ULF"; echo finished > "$FAKE_TMP/lc-finished"; exit 0' TERM
echo $$ > "$FAKE_TMP/lc-started"
while :; do /bin/sleep 0.02; done
EOF
env UNITY_USERNAME=u UNITY_PASSWORD=p "${hub[@]}" bash "$script" activate > "$tmp/log" 2>&1 & runner=$!
ship_wait_until test -s "$tmp/lc-started"
kill -TERM "$runner"
if ! ship_wait_until runner_exited; then kill -KILL "$runner" "$(cat "$tmp/lc-started")" 2>/dev/null || true; fi
rc=0; wait "$runner" 2>/dev/null || rc=$?
check "TERM waits for a client that finishes activation; the valid licence keeps its seat" \
  '[ "$rc" = 143 ] && [ -f "$tmp/lc-finished" ] && ! kill -0 "$(cat "$tmp/lc-started")" 2>/dev/null && [ "$(calls release)" = 0 ] && [ -f "$state" ] && [ -z "$(env UNITY_USERNAME=u UNITY_PASSWORD=p bash -c '\''. "$1"; ulf_problem'\'' _ "$script")" ]'

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
