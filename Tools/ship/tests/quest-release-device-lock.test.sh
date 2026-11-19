#!/usr/bin/env bash
# One headset lock across independent consumer log roots. Synthetic adb only.
# shellcheck disable=SC2016 # assertions are evaluated by check.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; owner=''; cancel_owner=''; cancel_group=''; adb_group=''
cleanup() {
  if [ -n "$adb_group" ]; then kill -KILL -- "-$adb_group" 2>/dev/null || true; fi
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

# Kill the release owner and its step while isolated fake adb is still
# running. The other checkout must neither enter nor signal that group.
cat > "$tmp/isolated-owner.sh" <<'OWNER'
. "$QR_TEST_RELEASE"
. "${QR_TEST_RELEASE%/*}/tests/lib/quest-release-fixture.sh"
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = gtimeout ]; then return 1; fi
  builtin command "$@"
}
QR_LOGS="$QR_TEST_LOCK_TMP/isolated-consumer/logs"
mkdir -p "$QR_LOGS"
adb() {
  [ "$1" = -s ] && [ "$2" = "$QUEST_SERIAL" ] && [ "$3" = wait-for-device ] || return 99
  local group
  group="$(exec sh -c 'printf "%s\n" "$PPID"')"
  if [ "$scenario" = failed-drain ]; then
    hold_adb "$group" &
    # Do not leave the wrapper until its child has started.
    qr_fixture_wait_ready "$QR_TEST_LOCK_TMP/adb-ready" "$!"
  else
    hold_adb "$group"
  fi
}
hold_adb() {
  trap 'touch "$QR_TEST_LOCK_TMP/adb-signalled"; exit 1' TERM
  qr_fixture_ready "$QR_TEST_LOCK_TMP/adb-ready" "$1"
  if read -r -t 20 _ <&8; then touch "$QR_TEST_LOCK_TMP/adb-finished"; fi
}
mutate() { qr_timebox '' adb -s "$QUEST_SERIAL" wait-for-device; }
scenario="${1:-}"
if [ "$scenario" = failed-drain ]; then
  # Inject the failed drain, not lock or registration behavior.
  qr_timebox_drain() { return 1; }
  qr_device_locked mutate
else
  qr_lock_acquire && qr_run_step qr_device_locked mutate
fi
OWNER
exec 8<> "$tmp/release"
qr_fixture_bash "$tmp/isolated-owner.sh" > "$tmp/isolated.out" 2>&1 & cancel_owner=$!
qr_fixture_wait_ready "$tmp/adb-ready" "$cancel_owner" || { cat "$tmp/isolated.out"; exit 1; }
read -r adb_group < "$tmp/adb-ready"
read -r cancel_group < "$tmp/isolated-consumer/logs/run.lock/group"
[[ "$adb_group" =~ ^[1-9][0-9]*$ && "$cancel_group" =~ ^[1-9][0-9]*$ && "$adb_group" != "$cancel_group" ]] || exit 1
kill -KILL "$cancel_owner" && kill -KILL -- "-$cancel_group" || exit 1
wait "$cancel_owner" 2>/dev/null || true
cancel_owner=''
await_group_exit() {
  local deadline=$((SECONDS + 8)) status
  while :; do
    status=0; qr_group_alive "$1" || status=$?
    [ "$status" != 1 ] || return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}
await_group_exit "$cancel_group" || exit 1
cancel_group=''
rc=0
(
  QR_LOGS="$tmp/isolated-successor/logs"
  qr_device_locked touch "$tmp/during-adb-mutation"
) > "$tmp/out" 2>&1 || rc=$?
check 'another checkout cannot reclaim the headset while isolated adb lives without its owner or step' \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/during-adb-mutation" ] && qr_group_alive "$adb_group" && [ ! -f "$tmp/adb-signalled" ] && grep -q "another quest-release run is active" "$tmp/out"'
printf 'finish\n' >&8; exec 8>&-
await_group_exit "$adb_group" || exit 1
adb_group=''
rc=0
(
  QR_LOGS="$tmp/isolated-successor/logs"
  qr_device_locked touch "$tmp/after-adb-mutation"
) > "$tmp/out" 2>&1 || rc=$?
check 'dead isolated adb does not make the abandoned headset lock unreclaimable' \
  '[ "$rc" = 0 ] && [ -f "$tmp/adb-finished" ] && [ -f "$tmp/after-adb-mutation" ]'

# A normal EXIT after an unconfirmed drain must also retain the headset
# lock. Run without a step, as performance cancellation recovery can do.
rm -f "$tmp/adb-ready" "$tmp/adb-finished"
exec 8<> "$tmp/release"
qr_fixture_bash "$tmp/isolated-owner.sh" failed-drain > "$tmp/isolated.out" 2>&1 & cancel_owner=$!
qr_fixture_wait_ready "$tmp/adb-ready" "$cancel_owner" || { cat "$tmp/isolated.out"; exit 1; }
read -r adb_group < "$tmp/adb-ready"
[[ "$adb_group" =~ ^[1-9][0-9]*$ ]] || exit 1
owner_rc=0; wait "$cancel_owner" || owner_rc=$?
cancel_owner=''
rc=0
(
  QR_LOGS="$tmp/isolated-successor/logs"
  qr_device_locked touch "$tmp/during-failed-drain"
) > "$tmp/out" 2>&1 || rc=$?
check 'failed drain retains the headset lock after its wrapper exits, without signalling adb' \
  '[ "$owner_rc" = 1 ] && [ "$rc" != 0 ] && [ ! -f "$tmp/during-failed-drain" ] && qr_group_alive "$adb_group" && [ ! -f "$tmp/adb-signalled" ] && grep -q "another quest-release run is active" "$tmp/out"'
printf 'finish\n' >&8; exec 8>&-
await_group_exit "$adb_group" || exit 1
adb_group=''
rc=0
(
  QR_LOGS="$tmp/isolated-successor/logs"
  qr_device_locked touch "$tmp/after-failed-drain"
) > "$tmp/out" 2>&1 || rc=$?
check 'a retained record from a failed drain can be reclaimed after adb exits' \
  '[ "$rc" = 0 ] && [ -f "$tmp/adb-finished" ] && [ -f "$tmp/after-failed-drain" ]'

# Doctor has no release run lock. Kill its real shell PID after the fake adb
# reconnect starts, leaving the isolated recovery worker in flight.
cat > "$tmp/doctor-owner.sh" <<'OWNER'
. "$QR_TEST_RELEASE"
QR_LOGS="$QR_TEST_LOCK_TMP/doctor-consumer/logs"
QR_DEVICE_CHECK_WAIT=15
qr_doctor_line() { :; }
qr_device_status() {
  [ -f "$QR_TEST_LOCK_TMP/doctor-done" ] || { echo offline; return 2; }
}
qr_idle_verdict() { :; }
adb() {
  [ "$1" = -s ] && [ "$2" = "$QUEST_SERIAL" ] || return 99
  case "$3" in
    reconnect)
      qr_fixture_ready "$QR_TEST_LOCK_TMP/doctor-ready" ready
      read -r -t 15 _ <&8 ;;
    wait-for-device) touch "$QR_TEST_LOCK_TMP/doctor-done" ;;
    *) return 99 ;;
  esac
}
. "${QR_TEST_RELEASE%/*}/tests/lib/quest-release-fixture.sh"
qr_doctor_device
OWNER
QUEST_SERIAL="synthetic-doctor-${tmp##*/}"
doctor_lock="/tmp/yetikit-quest-device-locks-$UID/$(printf '%s' "$QUEST_SERIAL" | qr_sha256).lock"
exec 8<> "$tmp/release"
bash "$tmp/doctor-owner.sh" > "$tmp/doctor.out" 2>&1 & owner=$!
ready=1; qr_fixture_wait_ready "$tmp/doctor-ready" "$owner" || ready=0
kill -KILL "$owner" 2>/dev/null || ready=0
wait "$owner" 2>/dev/null || true
owner=''
QR_LOGS="$tmp/doctor-successor/logs"
rc=0; qr_device_locked touch "$tmp/during-reconnect-mutation" > "$tmp/out" 2>&1 || rc=$?
check 'headset stays locked when the doctor owner dies during reconnect' \
  '[ "$ready" = 1 ] && [ "$rc" != 0 ] && [ ! -f "$tmp/doctor-done" ] && [ ! -f "$tmp/during-reconnect-mutation" ] && grep -q "another quest-release run is active" "$tmp/out"'
printf 'finish\n' >&8
exec 8>&-
# Give the surviving supervisor time to reap and release before retrying.
doctor_deadline=$((SECONDS + 10))
until [ -f "$tmp/doctor-done" ] && [ ! -e "$doctor_lock" ]; do
  [ "$SECONDS" -lt "$doctor_deadline" ] || break
  sleep 0.05
done
released=0; [ -e "$doctor_lock" ] || released=1
rc=0; qr_device_locked touch "$tmp/after-reconnect-mutation" > "$tmp/out" 2>&1 || rc=$?
check 'headset can be acquired after orphaned doctor recovery drains' \
  '[ -f "$tmp/doctor-done" ] && [ "$released" = 1 ] && [ "$rc" = 0 ] && [ -f "$tmp/after-reconnect-mutation" ]'
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
