#!/usr/bin/env bash
# One headset lock across independent consumer log roots. No adb/editor execution.
# shellcheck disable=SC2016 # assertions are evaluated by check.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; owner=''; cancel_owner=''; cancel_group=''
cleanup() {
  if [ -n "$owner" ]; then kill -TERM "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; fi
  if [ -n "$cancel_group" ]; then kill -KILL -- "-$cancel_group" 2>/dev/null || true; fi
  if [ -n "$cancel_owner" ]; then kill -KILL "$cancel_owner" 2>/dev/null || true; wait "$cancel_owner" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
. "$here/lib/quest-release-fixture.sh"
. "$here/../quest-release.sh"
# A unique synthetic serial avoids interference with other parallel fixture suites.
export QUEST_SERIAL="synthetic-lock-${tmp##*/}" QR_TEST_LOCK_TMP="$tmp"
export QR_TEST_RELEASE="$here/../quest-release.sh"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ ! -f "$tmp/out" ] || tail -n 10 "$tmp/out"; fails=$((fails + 1)); fi; }
cat > "$tmp/owner.sh" <<'OWNER'
. "$QR_TEST_RELEASE"
QR_LOGS="$QR_TEST_LOCK_TMP/consumer-a/logs"
mkdir -p "$QR_LOGS"
hold() {
  printf 'ready\n' > "$QR_TEST_LOCK_TMP/ready"
  read -r -t 20 _ <&8
}
qr_device_locked hold
OWNER
mkfifo "$tmp/release"; exec 8<> "$tmp/release"
bash "$tmp/owner.sh" > "$tmp/owner.out" 2>&1 & owner=$!
ready=1; qr_fixture_wait_ready "$tmp/ready" "$owner" || ready=0
rc=0
(
  QR_LOGS="$tmp/consumer-b/different-logs"; mkdir -p "$QR_LOGS"
  mutate() { touch "$tmp/unsafe-mutation"; }
  qr_device_locked mutate
) > "$tmp/out" 2>&1 || rc=$?
check 'same headset is locked across independent consumer log roots' \
  '[ "$ready" = 1 ] && [ "$rc" != 0 ] && [ ! -f "$tmp/unsafe-mutation" ] && grep -q "another quest-release run is active" "$tmp/out"'
# Another headset is independent, even while the first consumer holds its lock.
rc=0
(
  QUEST_SERIAL="synthetic-other-${tmp##*/}"
  QR_LOGS="$tmp/consumer-b/different-logs"
  qr_device_locked touch "$tmp/other-device"
) > "$tmp/out" 2>&1 || rc=$?
check 'a different synthetic headset has an independent lock' '[ "$rc" = 0 ] && [ -f "$tmp/other-device" ]'
printf 'finish\n' >&8
wait "$owner"; owner=''; exec 8>&-
rc=0
(
  QR_LOGS="$tmp/consumer-b/different-logs"
  qr_device_locked touch "$tmp/after-release"
) > "$tmp/out" 2>&1 || rc=$?
check 'another consumer can acquire the headset after release' '[ "$rc" = 0 ] && [ -f "$tmp/after-release" ]'
# Reproduce cancellation at the gap between a device wrapper exiting and its
# outer owner finishing TERM-resistant descendant cleanup. Pause only the outer
# drain, not production lock handling, to make the unsafe reacquisition deterministic.
cat > "$tmp/resistant.sh" <<'WORKER'
trap 'printf "term\n" > "$QR_TEST_LOCK_TMP/worker-term"' TERM
printf 'ready\n' > "$QR_TEST_LOCK_TMP/worker-ready"
deadline=$((SECONDS + 30))
while [ "$SECONDS" -lt "$deadline" ]; do read -r -t 1 _ <&7 || true; done
WORKER
cat > "$tmp/cancel-owner.sh" <<'OWNER'
. "$QR_TEST_RELEASE"
QR_LOGS="$QR_TEST_LOCK_TMP/cancel-consumer/logs"
mkdir -p "$QR_LOGS"
qr_lock_acquire || exit 1
trap 'qr_lock_release' EXIT
cmd=install
trap 'qr_cancel "$cmd" TERM' TERM
# Preserve the real escalation/reaping after the test releases the drain gate.
eval "$(declare -f qr_drain_group | sed '1s/qr_drain_group/real_drain_group/')"
qr_drain_group() {
  kill -TERM -- "-$1" 2>/dev/null || true
  deadline=$((SECONDS + 8))
  while [ ! -s "$QR_TEST_LOCK_TMP/worker-term" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
  read -r wrapper < "$QR_TEST_LOCK_TMP/wrapper.pid"
  while ps -p "$wrapper" -o stat= 2>/dev/null | grep -q '^[[:space:]]*[^Z[:space:]]'; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
  printf 'ready\n' > "$QR_TEST_LOCK_TMP/drain-paused"
  read -r -t 15 _ <&9 || true
  real_drain_group "$1"
}
mutate() {
  # $$ is the outer lock owner inside Bash subshells; PPID from a fresh shell
  # identifies the actual device wrapper whose EXIT trap is under test.
  bash -c 'printf "%s\n" "$PPID"' > "$QR_TEST_LOCK_TMP/wrapper.pid"
  bash "$QR_TEST_LOCK_TMP/resistant.sh" &
  wait "$!"
}
qr_run_step qr_device_locked mutate
OWNER
mkfifo "$tmp/worker-gate" "$tmp/drain-gate"
exec 7<> "$tmp/worker-gate" 9<> "$tmp/drain-gate"
qr_fixture_bash "$tmp/cancel-owner.sh" > "$tmp/cancel.out" 2>&1 & cancel_owner=$!
ready=1
qr_fixture_wait_ready "$tmp/worker-ready" "$cancel_owner" || ready=0
cancel_group="$(cat "$tmp/cancel-consumer/logs/run.lock/group" 2>/dev/null)"
kill -TERM "$cancel_owner" 2>/dev/null || true
qr_fixture_wait_ready "$tmp/drain-paused" "$cancel_owner" || ready=0
rc=0
(
  QR_LOGS="$tmp/cancel-successor/logs"; mkdir -p "$QR_LOGS"
  qr_device_locked touch "$tmp/during-drain-mutation"
) > "$tmp/out" 2>&1 || rc=$?
check 'cancelled device wrapper retains headset lock while TERM-resistant worker group lives' \
  '[ "$ready" = 1 ] && [ -n "$cancel_group" ] && qr_group_alive "$cancel_group" && [ "$rc" != 0 ] && [ ! -f "$tmp/during-drain-mutation" ] && grep -q "another quest-release run is active" "$tmp/out"'
printf 'drain\n' >&9
cancel_rc=0; wait "$cancel_owner" || cancel_rc=$?
cancel_owner=''
rc=0
(
  QR_LOGS="$tmp/cancel-successor/logs"
  qr_device_locked touch "$tmp/after-drain-mutation"
) > "$tmp/out" 2>&1 || rc=$?
check 'cancelled headset lock becomes reclaimable only after owner and worker group drain' \
  '[ "$cancel_rc" != 0 ] && ! qr_group_alive "$cancel_group" && [ "$rc" = 0 ] && [ -f "$tmp/after-drain-mutation" ]'
exec 7>&- 9>&-
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
