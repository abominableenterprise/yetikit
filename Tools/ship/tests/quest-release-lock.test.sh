#!/usr/bin/env bash
# Lock protocol regressions: fake steps only; no Unity, adb, or device.
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/quest-release.sh"
tmp="$(mktemp -d)"
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
fails=0
children=""
cleanup() {
  local pid
  for pid in $children; do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
check() {
  if eval "$2"; then echo "ok   $1"; else
    echo "FAIL $1"; fails=$((fails + 1))
    [ ! -f "$tmp/out" ] || cat "$tmp/out"
  fi
}
export RELEASE_SCRIPT="$script" LOCK_TMP="$tmp"
fixture_lib="$(dirname "$script")/tests/lib/quest-release-fixture.sh"
. "$fixture_lib"
export FIXTURE_LIB="$fixture_lib"

# Missing/empty PID metadata must retain its pre-claim age during revalidation.
for metadata in missing empty; do
  (
    . "$RELEASE_SCRIPT"
    QR_LOGS="$LOCK_TMP/aged-$metadata"; mkdir -p "$QR_LOGS/run.lock"
    qr_log() { echo "$*"; }
    [ "$metadata" != empty ] || : > "$QR_LOGS/run.lock/pid"
    touch -t 200001010000 "$QR_LOGS/run.lock"
    qr_lock_acquire && qr_lock_release
    [ ! -e "$QR_LOGS/run.lock" ]
  ) > "$tmp/out" 2>&1
  aged_rc=$?
  check "an aged lock with $metadata PID metadata is reclaimable" '[ "$aged_rc" = 0 ]'
done
# Fail the initial PID redirection even under root. Acquisition must not return success or leave an ownerless lock.
(
  . "$RELEASE_SCRIPT"
  QR_LOGS="$LOCK_TMP/metadata"; mkdir -p "$QR_LOGS"
  qr_log() { echo "$*"; }
  mkdir() {
    command mkdir "$@" || return
    case "$*" in */run.lock) command mkdir "$QR_LOGS/run.lock/pid" ;; esac
  }
  rc=0; qr_lock_acquire || rc=$?
  [ "$rc" != 0 ] && [ "${QR_LOCK_HELD:-}" != 1 ] && [ ! -e "$QR_LOGS/run.lock" ]
) > "$tmp/out" 2>&1
metadata_rc=$?
check 'failed PID metadata publication aborts and removes the unowned lock' '[ "$metadata_rc" = 0 ]'

# A reclaimer pauses AFTER reading a dead owner. A second reclaimer wins and stays alive; the first must
# revalidate under its claim rather than delete the successor using its cached stale observation.
cat > "$tmp/reclaimer.sh" <<'RECLAIMER'
. "$RELEASE_SCRIPT"
QR_LOGS="$LOCK_TMP/race"
qr_log() { echo "$*"; }
eval "$(declare -f qr_lock_read | sed '1s/qr_lock_read/real_lock_read/')"
qr_lock_read() {
  local rc=0
  real_lock_read || rc=$?
  if [ "$rc" = 2 ] && [ ! -f "$LOCK_TMP/observed" ]; then
    touch "$LOCK_TMP/observed"
    echo stale > "$LOCK_TMP/observed-pipe"
    read -r -t 10 _ < "$LOCK_TMP/resume-pipe" || return 1
  fi
  return "$rc"
}
rc=0; qr_lock_acquire || rc=$?
echo "$rc" > "$LOCK_TMP/reclaimer.rc"
[ "$rc" != 0 ] || qr_lock_release
RECLAIMER
mkdir -p "$tmp/race/run.lock"
# Get a certainly dead numeric PID without assuming a platform's pid_max.
bash -c 'exit 0' & dead=$!; wait "$dead" 2>/dev/null || true
echo "$dead" > "$tmp/race/run.lock/pid"
mkfifo "$tmp/observed-pipe" "$tmp/resume-pipe"; exec 8<> "$tmp/observed-pipe" 9<> "$tmp/resume-pipe"
bash "$tmp/reclaimer.sh" > "$tmp/out" 2>&1 & reclaimer=$!; children="$children $reclaimer"
observed=1; read -r -t 10 _ <&8 || observed=0
mkfifo "$tmp/winner-release"; exec 7<> "$tmp/winner-release"
(
  . "$RELEASE_SCRIPT"; QR_LOGS="$LOCK_TMP/race"; qr_log() { echo "$*"; }
  qr_lock_acquire && echo acquired > "$LOCK_TMP/winner-pipe"
  read -r -t 10 _ < "$LOCK_TMP/winner-release" || true
  qr_lock_release
) > "$tmp/winner.out" 2>&1 & winner=$!; children="$children $winner"
# A regular-file handshake bounds acquisition without blocking publication.
n=0; while [ ! -s "$tmp/winner-pipe" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
echo resume >&9
wait "$reclaimer"
check 'a delayed stale reclaimer cannot remove a live successor' \
  '[ "$observed" = 1 ] && [ -s "$tmp/winner-pipe" ] && [ "$(cat "$tmp/reclaimer.rc")" = 1 ] && [ -d "$tmp/race/run.lock" ]'
echo release >&7
wait "$winner" 2>/dev/null || true
exec 7>&- 8>&- 9>&-

cat > "$tmp/run.sh" <<'RUN'
. "$RELEASE_SCRIPT"
qr_java_setup() { :; }
qr_load_state() { QR_RUN_DIR="$LOCK_TMP/run"; }
qr_summary() { :; }
qr_prepare() { echo entered >> "$LOCK_TMP/prepares"; bash "$LOCK_TMP/worker.sh"; }
qr_verify() { echo verify >> "$LOCK_TMP/dispatched"; }
qr_launch() { echo launch >> "$LOCK_TMP/dispatched"; }
qr_main "$1"
RUN
cat > "$tmp/worker.sh" <<'WORKER'
trap '' TERM HUP INT
# This process survives a parent-only KILL and keeps the step process group busy.
echo "$$" > "$LOCK_TMP/worker.pid"
echo ready > "$LOCK_TMP/ready"
read -r -t 20 _ < "$LOCK_TMP/worker-release" || true
WORKER
export QUEST_LOG_ROOT="$tmp/logs" QUEST_WT_ROOT="$tmp/wt"
mkdir -p "$tmp/run"
mkfifo "$tmp/ready" "$tmp/worker-release"; exec 8<> "$tmp/ready" 9<> "$tmp/worker-release"
set -m
bash "$tmp/run.sh" prepare > "$tmp/out" 2>&1 & owner=$!; children="$children $owner"
set +m
ready=1; read -r -t 10 _ <&8 || ready=0
worker="$(cat "$tmp/worker.pid" 2>/dev/null)"; children="$children $worker"
# Two real concurrent qr_main invocations, not a fabricated lock: the refused prepare must not touch state.
printf 'unchanged\n' > "$tmp/logs/current.env"
cp "$tmp/logs/current.env" "$tmp/current.before"
rc=0; bash "$tmp/run.sh" prepare > "$tmp/overlap.out" 2>&1 || rc=$?
check 'a concurrent prepare refuses before dispatch or state changes' \
  '[ "$ready" = 1 ] && [ "$rc" = 1 ] && [ "$(wc -l < "$tmp/prepares" | tr -d " ")" = 1 ] && cmp -s "$tmp/current.before" "$tmp/logs/current.env"'
kill -KILL "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
for cmd in verify launch; do
  rc=0; bash "$tmp/run.sh" "$cmd" > "$tmp/overlap.out" 2>&1 || rc=$?
  check "$cmd remains locked after parent-only SIGKILL while orphan worker group is alive" \
    '[ "$ready" = 1 ] && [ "$rc" = 1 ] && [ ! -e "$tmp/dispatched" ] && [ -d "$tmp/logs/run.lock" ]'
done
echo finish >&9
# Group cleanup can finish asynchronously after the worker exits. Bound polling and ignore zombies.
. "$script"
group="$(cat "$tmp/logs/run.lock/group" 2>/dev/null)"
case "$group" in ''|*[!0-9]*) group="$worker" ;; esac
n=0; while qr_group_alive "$group" && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
rc=0; bash "$tmp/run.sh" verify > "$tmp/out" 2>&1 || rc=$?
check 'a dead owner becomes reclaimable only after its orphan group exits' \
  '[ "$rc" = 0 ] && grep -q "^verify$" "$tmp/dispatched" && [ ! -e "$tmp/logs/run.lock" ]'
exec 8>&- 9>&-

# Pause a worker before its owner's group publication, kill the owner, and hold a successor step open.
# The old worker must not accept the successor's authorization when it resumes.
cat > "$tmp/generation.sh" <<'GENERATION'
. "$RELEASE_SCRIPT"
. "$FIXTURE_LIB"
QR_LOGS="$LOCK_TMP/generation"
qr_log() { echo "$*"; }
qr_lock_acquire || exit 1
if [ "$1" = old ]; then
  printf() {
    if [ "${QR_REGISTERING_STEP:-}" = 1 ] && [ "$BASH_SUBSHELL" = 0 ]; then
      read -r -t 60 _ < "$LOCK_TMP/owner-resume" || return 1
    fi
    command printf "$@"
  }
  sleep() {
    qr_fixture_ready "$LOCK_TMP/old-paused" paused
    read -r -t 60 _ < "$LOCK_TMP/old-resume" || exit 1
    command sleep "$@"
  }
  old_step() { echo unsafe > "$LOCK_TMP/old-dispatched"; }
  qr_run_step old_step
else
  successor_step() {
    qr_fixture_ready "$LOCK_TMP/successor-ready" ready
    read -r -t 60 _ < "$LOCK_TMP/successor-resume" || true
  }
  qr_run_step successor_step
  qr_lock_release
fi
GENERATION
mkfifo "$tmp/owner-resume" "$tmp/old-resume" "$tmp/successor-resume"
exec 7<> "$tmp/owner-resume" 8<> "$tmp/old-resume" 9<> "$tmp/successor-resume"
mkdir -p "$tmp/generation"
qr_fixture_bash "$tmp/generation.sh" old > "$tmp/old.out" 2>&1 & old_owner=$!; children="$children $old_owner"
ready=1; qr_fixture_wait_ready "$tmp/old-paused" "$old_owner" || ready=0
# The child PID is not yet in group; enumerate only this owner's direct child for bounded cleanup/assertion.
old_worker="$(ps -axo pid=,ppid= | awk -v owner="$old_owner" '$2 == owner { print $1 }')"
children="$children $old_worker"
kill -KILL "$old_owner" 2>/dev/null || true; wait "$old_owner" 2>/dev/null || true
qr_fixture_bash "$tmp/generation.sh" successor > "$tmp/successor.out" 2>&1 & successor=$!; children="$children $successor"
qr_fixture_wait_ready "$tmp/successor-ready" "$successor" || ready=0
echo resume >&8
n=0
while ps -p "$old_worker" -o stat= | grep -qv '^[[:space:]]*Z' && [ "$n" -lt 200 ]; do
  command sleep 0.05; n=$((n + 1))
done
check 'an unpublished orphan worker cannot use a successor step authorization' \
  '[ "$ready" = 1 ] && [ ! -f "$tmp/old-dispatched" ] && ! ps -p "$old_worker" -o stat= | grep -qv "^[[:space:]]*Z"'
echo finish >&9
wait "$successor" 2>/dev/null || true
exec 7>&- 8>&- 9>&-
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
