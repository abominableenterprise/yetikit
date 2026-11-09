#!/usr/bin/env bash
# test-all: serial
# Cross-output serialization and activation cancellation. Never runs Unity or touches the network.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

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
