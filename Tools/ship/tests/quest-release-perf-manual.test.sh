#!/usr/bin/env bash
# Manual performance windows: real run and device locks, synthetic adb only.
# shellcheck disable=SC2016 # checks are evaluated in fixture scope
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release.sh"
. "$here/lib/quest-release-config.sh"
. "$here/lib/quest-release-fixture.sh"
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = gtimeout ]; then return 1; fi
  builtin command "$@"
}
jq() { command "${SHIP_TEST_REAL_JQ:-jq}" "$@"; }
serial_id() {
  case "$1" in "$a") echo a ;; "$b") echo b ;; *) return 99 ;; esac
}
qr_perf_now() {
  command cat "$tmp/$(serial_id "$QUEST_SERIAL").host"
}
adb() {
  local id lock
  [ "${1:-}" = -s ] && [ "$#" -ge 3 ] || return 99
  id="$(serial_id "$2")" || return 99; shift 2
  printf '%s|%s\n' "$id" "$*" >> "$tmp/events"
  case "$*" in
    get-state) echo device ;;
    'shell getprop ro.product.manufacturer') echo Oculus ;;
    'shell getprop ro.product.model') echo 'Synthetic Quest' ;;
    'shell dumpsys package '*) echo 'versionName=synthetic-build'; echo 'versionCode=42' ;;
    'shell dumpsys thermalservice'|'shell pm path '*) return 1 ;;
    'shell pidof '*) printf '4242\nqr_pid_rc=0\n' ;;
    'shell dumpsys activity activities') printf 'mResumedActivity: ActivityRecord{abc u0 %s/.Main t1}\n' "$QR_PKG" ;;
    'shell date +%s.%N') command cat "$tmp/$id.epoch" ;;
    'shell am broadcast -a com.oculus.vrpowermanager.prox_close')
      : > "$tmp/$id.override"
      if [ "${QR_MANUAL_BLOCK:-}" = start ]; then qr_fixture_block_until_term "$tmp/blocker"; fi ;;
    'shell am broadcast -a com.oculus.vrpowermanager.automation_disable')
      lock="$(marker_for "${id}")"; lock="${lock%.manual}.lock"
      if [ "$(command cat "$lock/pid" 2>/dev/null)" != "$$" ]; then : > "$tmp/unlocked-restore"; fi
      [ ! -e "$tmp/$id.restore-fails" ] || return 1
      rm -f "$tmp/$id.override" ;;
    'logcat -d -v epoch -v usec --pid=4242 -s VrApi')
      if [ "${QR_MANUAL_BLOCK:-}" = stop ]; then qr_fixture_block_until_term "$tmp/blocker"; fi
      command cat "$tmp/$id.samples" ;;
    *) return 99 ;;
  esac
}
marker_for() {
  local serial="$a"
  [ "$1" != b ] || serial="$b"
  printf '/tmp/yetikit-quest-device-locks-%s/%s.manual\n' "$UID" "$(printf '%s' "$serial" | qr_sha256)"
}
if [ "${1:-}" = --worker ]; then
  tmp="$QR_MANUAL_TMP"; a="$QR_MANUAL_A"; b="$QR_MANUAL_B"; shift
  qr_main perf "$@"; exit $?
fi

tmp="$(mktemp -d)"; owner=''
token="${tmp##*/}"; token="${token//./-}"
a="synthetic-manual-A-$token"; b="synthetic-manual-B-$token"
export QR_MANUAL_TMP="$tmp" QR_MANUAL_A="$a" QR_MANUAL_B="$b"
export QUEST_REPO="$tmp" QUEST_LOG_ROOT="$tmp/logs" QUEST_WT_ROOT="$tmp/wt"
export QUEST_ADB_WAIT=1 QR_PERF_RESTORE_WAIT=1
cleanup() {
  if [ -n "$owner" ]; then kill -TERM "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; fi
  local id marker
  for id in a b; do marker="$(marker_for "$id")"; rm -f "$marker" "$marker.tmp"; done
  rm -rf "$tmp"
}
trap cleanup EXIT
qr_test_config "$tmp/config"
jq '.quest.perf.devices["Synthetic Quest"] = "gate"' "$YETIKIT_CONFIG" > "$tmp/gate.json"
mv "$tmp/gate.json" "$YETIKIT_CONFIG"
fails=0
check() {
  if eval "$2"; then echo "ok $1"; else echo "FAIL $1 (rc=${rc:-?})"; tail -n 15 "$tmp/out"; fails=$((fails + 1)); fi
}
clock() { printf '%s\n' "$2" > "$tmp/$1.epoch"; printf '%s\n' "$3" > "$tmp/$1.host"; }
run() {
  export QUEST_SERIAL="$1"; shift
  rc=0; ( qr_main "$@" ) > "$tmp/out" 2>&1 || rc=$?
  run_dir="$(. "$QUEST_LOG_ROOT/current.env" && printf '%s' "$QR_RUN_DIR")"
  report="$run_dir/perf-summary.json"
}
json() { jq -e "$1" "${2:-$report}" >/dev/null; }
sample() { printf '%s 4242 4242 I VrApi: FPS=72,Stale=0,%s\n' "$1" "$2"; }

run "$a" perf stop
check 'unmatched stop fails clearly and never touches adb' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and (.message | contains("no matching perf start"))'\'' && [ ! -e "$tmp/events" ]'
clock a 1700000000.250000001 1000
clock b 1700000100.750000000 2000
rc=0; QUEST_SERIAL="$a,$b" bash "$0" --worker start > "$tmp/out" 2>&1 || rc=$?
run_dir="$(. "$QUEST_LOG_ROOT/current.env" && printf '%s' "$QR_RUN_DIR")"
check 'start reserves each running app without launching or clearing logs' \
  '[ "$rc" = 0 ] && [ -f "$tmp/a.override" ] && [ -f "$tmp/b.override" ] && ! grep -Eq "am start|logcat" "$tmp/events" && [ ! -e "$run_dir/devices/$a/perf-summary.json" ] && [ ! -e "$run_dir/devices/$b/perf-summary.json" ]'
key_a="$(marker_for a)"; key_b="$(marker_for b)"
check 'device edges are persisted independently' \
  'json '\''.start == "1700000000.250000001"'\'' "$key_a" && json '\''.start == "1700000100.750000000"'\'' "$key_b"'
cp "$key_a" "$tmp/original"
run "$a" perf start
check 'duplicate start does not replace the window or restore its sensor' \
  '[ "$rc" = 3 ] && cmp -s "$tmp/original" "$key_a" && [ -e "$tmp/a.override" ] && grep -q "already pending" "$tmp/out"'
rc=0
( QUEST_LOG_ROOT="$tmp/other-logs" run "$a" perf stop; printf '%s\n' "$rc" > "$tmp/foreign-rc" )
read -r rc < "$tmp/foreign-rc"
check 'foreign stop cannot consume or restore the window' \
  '[ "$rc" = 3 ] && cmp -s "$tmp/original" "$key_a" && [ -e "$tmp/a.override" ] && grep -q "not owned" "$tmp/out"'
( QUEST_LOG_ROOT="$tmp/other-logs" run "$a" launch; printf '%s\n' "$rc" > "$tmp/foreign-rc" )
read -r rc < "$tmp/foreign-rc"
check 'competing device mutation is refused across log roots' \
  '[ "$rc" = 3 ] && grep -q "pending manual capture" "$tmp/out" && ! grep -q "am start" "$tmp/events"'
{
  sample 1700000000.250000 'App=999ms' # one nanosecond before start
  sample 1700000000.500000 'App=5ms'; sample 1700000001.500000 'App=6ms'
  sample 1700000002.250000 'App=999ms' # exactly at stop
} > "$tmp/a.samples"
{
  sample 1700000100.500000 'App=999ms'
  sample 1700000101.000000 ''; sample 1700000102.000000 ''
  sample 1700000102.750000 'App=999ms'
} > "$tmp/b.samples"
clock a 1700000002.250000000 3000
clock b 1700000102.750000000 4000
# A new release run must not strand the original device reservations.
( qr_config && qr_new_run '1111111111111111' synthetic )
rc=0; QUEST_SERIAL="$b,$a" bash "$0" --worker stop > "$tmp/out" 2>&1 || rc=$?
run_dir="$(. "$QUEST_LOG_ROOT/current.env" && printf '%s' "$QR_RUN_DIR")"
check 'stop bounds both logcat artifacts and emits the normal text and JSON from persisted edges' \
  '[ "$rc" = 1 ] && json '\''.overall == "PASS" and .samples == 2 and .p95AppMs == 6 and .seconds == 2 and .warmupSeconds == 0 and .scene == "unavailable" and .versionName == "synthetic-build" and .apkSha256 == "unavailable" and .thermalStart == "unavailable"'\'' "$run_dir/devices/$a/perf-summary.json" && grep -q "Quest performance: PASS" "$run_dir/devices/$a/perf-summary.txt" && ! grep -q "999ms" "$run_dir"/devices/*/perf-logcat.txt'
check 'missing gate input stays unavailable and both sensors are restored under lock' \
  'json '\''.overall == "FAIL" and .samples == 2 and .gates.app.value == "unavailable"'\'' "$run_dir/devices/$b/perf-summary.json" && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/b.override" ] && [ ! -e "$tmp/unlocked-restore" ] && [ ! -e "$key_a" ] && [ ! -e "$key_b" ]'
run "$a" perf stop
check 'a completed stop cannot reuse its start' '[ "$rc" = 3 ] && grep -q "no matching perf start" "$tmp/out"'

cancel() {
  local action="$1"
  rm -f "$tmp/blocker.started" "$tmp/blocker.terminated"
  ( export QUEST_SERIAL="$a" QR_MANUAL_BLOCK="$action"; qr_fixture_bash "$0" --worker "$action" ) > "$tmp/out" 2>&1 & owner=$!
  if qr_fixture_wait_ready "$tmp/blocker.started" "$owner"; then kill -TERM "$owner"; fi
  rc=0; wait "$owner" || rc=$?; owner=''
  run_dir="$(. "$QUEST_LOG_ROOT/current.env" && printf '%s' "$QR_RUN_DIR")"
  report="$run_dir/perf-summary.json"
}
cancel start
check 'cancelling start drains the broadcast and restores before clearing ownership' \
  '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && json '\''.message == "capture cancelled"'\'' '
run "$b" perf start
run "$a" perf start
clock a 1700000004.250000000 5000
: > "$tmp/a.restore-fails"
cancel stop
check 'cancelling stop with adb restoration failure keeps recovery state but not a reusable window' \
  '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && json '\''has("start") | not'\'' "$key_a" && [ -e "$tmp/a.override" ] && [ -e "$tmp/b.override" ] && grep -q "retry perf stop" "$tmp/out"'
rm -f "$tmp/a.restore-fails"
run "$a" perf stop
check 'retry stop recovers the cancelled device only and does not report stale success' \
  '[ "$rc" = 3 ] && grep -q "restoring proximity only" "$tmp/out" && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ -e "$key_b" ] && [ -e "$tmp/b.override" ]'
clock b invalid 5000
run "$b" perf stop
check 'unavailable stop clock reports INFRA and still restores proximity' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0 and (.message | contains("invalid adb capture clock"))'\'' && [ ! -e "$key_b" ] && [ ! -e "$tmp/b.override" ]'
[ "$fails" = 0 ] || exit 1
echo 'all passed'
