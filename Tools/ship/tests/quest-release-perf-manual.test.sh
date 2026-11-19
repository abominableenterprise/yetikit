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
mv() {
  command mv "$@" || return $?
  if [ "${QR_MANUAL_BLOCK:-}" = committed-start ] && [ "${3:-}" = "$(marker_for a)" ] &&
     jq -e 'has("start")' "$3" >/dev/null; then
    qr_fixture_block_until_term "$tmp/blocker"
  elif [ "${QR_MANUAL_BLOCK:-}" = stop-journal ] && [[ "${3:-}" = */run.lock/perf-manual/*.manual ]]; then
    qr_fixture_block_until_term "$tmp/blocker"
  fi
}
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
  if [ -e "$tmp/$id.offline" ] && [ "$*" != 'shell am broadcast -a com.oculus.vrpowermanager.automation_disable' ]; then return 1; fi
  case "$*" in
    get-state) echo device ;;
    'shell getprop ro.product.manufacturer') echo Oculus ;;
    'shell getprop ro.product.model') echo 'Synthetic Quest' ;;
    'shell dumpsys package '*) echo 'versionName=synthetic-build'; echo 'versionCode=42' ;;
    'shell dumpsys thermalservice'|'shell pm path '*) return 1 ;;
    'shell pidof '*) printf '4242\nqr_pid_rc=0\n' ;;
    'shell dumpsys activity activities') printf 'mResumedActivity: ActivityRecord{abc u0 %s/.Main t1}\n' "$QR_PKG" ;;
    'shell date +%s.%N')
      [ ! -e "$tmp/$id.clock-fails" ] || return 1
      command cat "$tmp/$id.epoch" ;;
    'shell am broadcast -a com.oculus.vrpowermanager.prox_close')
      : > "$tmp/$id.override"
      if [ "${QR_MANUAL_BLOCK:-}" = start ]; then qr_fixture_block_until_term "$tmp/blocker"; fi ;;
    'shell am broadcast -a com.oculus.vrpowermanager.automation_disable')
      lock="$(marker_for "${id}")"; lock="${lock%.manual}.lock"
      if [ "$(command cat "$lock/pid" 2>/dev/null)" != "$$" ]; then : > "$tmp/unlocked-restore"; fi
      [ ! -e "$tmp/$id.restore-fails" ] && [ ! -e "$tmp/$id.offline" ] || return 1
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
a_path="$(qr_serial_path "$a")"; b_path="$(qr_serial_path "$b")"
export QR_MANUAL_TMP="$tmp" QR_MANUAL_A="$a" QR_MANUAL_B="$b"
export QUEST_REPO="$tmp" QUEST_LOG_ROOT="$tmp/logs" QUEST_WT_ROOT="$tmp/wt"
export QUEST_ADB_WAIT=1 QR_PERF_RESTORE_WAIT=1
cleanup() {
  if [ -n "$owner" ]; then kill -TERM "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; fi
  local id marker
  for id in a b; do
    marker="$(marker_for "$id")"
    if [ -d "$marker.tmp" ]; then rmdir "$marker.tmp"; fi
    rm -f "$marker" "$marker.tmp"
  done
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
  '[ "$rc" = 0 ] && [ -f "$tmp/a.override" ] && [ -f "$tmp/b.override" ] && ! grep -Eq "am start|logcat" "$tmp/events" && [ ! -e "$run_dir/devices/$a_path/perf-summary.json" ] && [ ! -e "$run_dir/devices/$b_path/perf-summary.json" ]'
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
  '[ "$rc" = 1 ] && json '\''.overall == "PASS" and .samples == 2 and .p95AppMs == 6 and .seconds == 2 and .warmupSeconds == 0 and .scene == "unavailable" and .versionName == "synthetic-build" and .apkSha256 == "unavailable" and .thermalStart == "unavailable"'\'' "$run_dir/devices/$a_path/perf-summary.json" && grep -q "Quest performance: PASS" "$run_dir/devices/$a_path/perf-summary.txt" && ! grep -q "999ms" "$run_dir"/devices/*/perf-logcat.txt'
check 'missing gate input stays unavailable and both sensors are restored under lock' \
  'json '\''.overall == "FAIL" and .samples == 2 and .gates.app.value == "unavailable"'\'' "$run_dir/devices/$b_path/perf-summary.json" && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/b.override" ] && [ ! -e "$tmp/unlocked-restore" ] && [ ! -e "$key_a" ] && [ ! -e "$key_b" ]'
run "$a" perf stop
check 'a completed stop cannot reuse its start' '[ "$rc" = 3 ] && grep -q "no matching perf start" "$tmp/out"'

# Drop DAC overrides in root-run workers so real mode bits still apply.
permission_shell=(bash)
if [ "$UID" = 0 ]; then permission_shell=(setpriv --bounding-set=-dac_override,-dac_read_search bash); fi
cancel() {
  local action="$1" block="${2:-$1}" fault="${3:-}"
  rm -f "$tmp/blocker.started" "$tmp/blocker.terminated"
  (
    export QUEST_SERIAL="$a" QR_MANUAL_BLOCK="$block"
    if [ "$block" = stop-journal ]; then
      exec "${permission_shell[@]}" "$0" --worker "$action"
    fi
    qr_fixture_bash "$0" --worker "$action"
  ) > "$tmp/out" 2>&1 & owner=$!
  if qr_fixture_wait_ready "$tmp/blocker.started" "$owner"; then
    # Fail the recovery write even when this fixture runs as root, without
    # interfering with the device lock or the ability to unlink the record.
    if [ "$fault" = save-fails ]; then mkdir "$key_a.tmp" || exit 1; fi
    kill -TERM "$owner"
  fi
  rc=0; wait "$owner" || rc=$?; owner=''
  if [ -d "$key_a.tmp" ]; then rmdir "$key_a.tmp" || exit 1; fi
  run_dir="$(. "$QUEST_LOG_ROOT/current.env" && printf '%s' "$QR_RUN_DIR")"
  report="$run_dir/perf-summary.json"
}
cancel start
check 'cancelling start drains the broadcast and restores before clearing ownership' \
  '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && json '\''.message == "capture cancelled"'\'' '
cancel start committed-start save-fails
check 'cancelling a committed start still restores under lock without rewriting the reservation' \
  '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/unlocked-restore" ] && json '\''.overall == "INFRA" and .message == "capture cancelled"'\'' && ! grep -q "retry perf stop" "$tmp/out"'
run "$b" perf start
: > "$tmp/a.restore-fails"
: > "$tmp/events"
cancel start committed-start save-fails
check 'a failed broadcast leaves the original reservation pending under its owner' \
  '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && json '\''has("start")'\'' "$key_a" && [ -e "$tmp/a.override" ] && [ -e "$tmp/b.override" ] && [ ! -e "$tmp/unlocked-restore" ] && grep -q "^a|.*automation_disable" "$tmp/events" && grep -q "retry perf stop" "$tmp/out"'
rm -f "$tmp/a.restore-fails"
clock a 1700000004.250000000 5000
sample 1700000003.000000 'App=5ms' > "$tmp/a.samples"
run "$a" perf stop
check 'retry stop restores only and never reads the cancelled window, even after the reservation is writable again' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0'\'' && grep -q "restoring proximity only" "$tmp/out" && ! grep -q "logcat" "$tmp/events" && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ -e "$key_b" ] && [ -e "$tmp/b.override" ]'
run "$a" perf start
check 'a new start can rearm the guard in the same run' \
  '[ "$rc" = 0 ] && json '\''has("start")'\'' "$key_a" && [ -e "$tmp/a.override" ]'
clock a 1700000006.250000000 7000
: > "$tmp/a.restore-fails"
cancel stop
check 'cancelling stop with adb restoration failure keeps recovery state but not a reusable window' \
  '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && [ -f "$key_a" ] && [ ! -s "$run_dir/${key_a##*/}.armed" ] && [ -e "$tmp/a.override" ] && [ -e "$tmp/b.override" ] && grep -q "retry perf stop" "$tmp/out"'
rm -f "$tmp/a.restore-fails"
run "$a" perf stop
check 'retry stop recovers the cancelled device only and does not report stale success' \
  '[ "$rc" = 3 ] && grep -q "restoring proximity only" "$tmp/out" && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ -e "$key_b" ] && [ -e "$tmp/b.override" ]'
clock b invalid 5000
run "$b" perf stop
check 'unavailable stop clock reports INFRA and still restores proximity' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0 and (.message | contains("invalid adb capture clock"))'\'' && [ ! -e "$key_b" ] && [ ! -e "$tmp/b.override" ]'
clock a 1700000150.000000000 6000
run "$a" perf start
check 'start commits a window before the stop reservation becomes unwritable' \
  '[ "$rc" = 0 ] && json '\''.start == "1700000150.000000000"'\'' "$key_a"'
# Run stop from a different run. The guard belongs to the original capture,
# not whichever run happens to receive the stop report.
( qr_config && qr_new_run '2222222222222222' synthetic ) || exit 1
mkdir "$key_a.tmp" || exit 1
: > "$tmp/a.restore-fails"
: > "$tmp/events"
clock a 1700000152.000000000 8000
: > "$tmp/a.clock-fails"
run "$a" perf stop
check 'offline stop with an unwritable reservation leaves recovery pending' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and (.message | contains("adb proximity restoration failed"))'\'' && json '\''has("start")'\'' "$key_a" && [ -e "$tmp/a.override" ] && grep -q "automation_disable" "$tmp/events" && ! grep -q "logcat" "$tmp/events"'
rmdir "$key_a.tmp" || exit 1
rm -f "$tmp/a.restore-fails" "$tmp/a.clock-fails"
: > "$tmp/events"
clock a 1700000154.000000000 10000
{ sample 1700000150.500000 'App=5ms'; sample 1700000153.000000 'App=6ms'; } > "$tmp/a.samples"
run "$a" perf stop
check 'retry after the offline stop restores proximity but reports the window as unknown' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0 and (.message | contains("stop boundary unknown"))'\'' && ! grep -Eq "shell date|logcat" "$tmp/events" && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/unlocked-restore" ]'
clock a 1700000160.000000000 16000
run "$a" perf start
start_dir="$run_dir"
check 'start commits the window for the triple failure' \
  '[ "$rc" = 0 ] && json '\''.start == "1700000160.000000000"'\'' "$key_a"'
( qr_config && qr_new_run '3333333333333333' synthetic ) || exit 1
# Reject both writes, but allow truncating an existing file as on a full disk.
# A dangling target fails the fallback redirection without leaving a flag that
# the retry would see (unlike a directory at the fallback path).
cancelled="$start_dir/${key_a##*/}.cancelled"
mkdir "$key_a.tmp" || exit 1
ln -s "$tmp/missing/cancelled" "$cancelled" || exit 1
: > "$tmp/a.restore-fails"
: > "$tmp/events"
clock a 1700000162.000000000 18000
: > "$tmp/a.clock-fails"
run "$a" perf stop
check 'stop leaves recovery pending even when both legacy invalidation writes are blocked' \
  '[ "$rc" = 3 ] && [ ! -e "$cancelled" ] && json '\''.overall == "INFRA" and .samples == 0 and (.message | contains("adb proximity restoration failed"))'\'' && [ -e "$key_a" ] && [ -e "$tmp/a.override" ] && grep -q "automation_disable" "$tmp/events" && ! grep -q "logcat" "$tmp/events"'
rmdir "$key_a.tmp" || exit 1
rm -f "$cancelled" "$tmp/a.restore-fails" "$tmp/a.clock-fails"
: > "$tmp/events"
clock a 1700000164.000000000 20000
{
  sample 1700000160.500000 'App=5ms'; sample 1700000161.500000 'App=5ms'
  sample 1700000162.500000 'App=6ms'; sample 1700000163.500000 'App=6ms'
} > "$tmp/a.samples"
run "$a" perf stop
check 'retry after the triple failure restores only, without a new clock edge or post-stop samples' \
  '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0 and (.message | contains("stop boundary unknown"))'\'' && ! grep -Eq "shell date|logcat" "$tmp/events" && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/unlocked-restore" ]'
# Start again in the same run and leave the previous capture's samples in the
# fake dump. Only telemetry from the new window should be eligible for PASS.
run "$a" perf start
check 'a fresh start after the triple failure commits a new window' \
  '[ "$rc" = 0 ] && json '\''.start == "1700000164.000000000"'\'' "$key_a"'
{ sample 1700000164.500000 'App=5ms'; sample 1700000165.500000 'App=5ms'; } >> "$tmp/a.samples"
clock a 1700000166.000000000 22000
run "$a" perf stop
check 'only the fresh window can publish PASS after the triple failure' \
  '[ "$rc" = 0 ] && json '\''.overall == "PASS" and .seconds == 2 and .samples == 2 and .p95AppMs == 5'\'' && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ]'
# Exercise both failed guard lookups and failed writes from another run.
for interruption in stop cancel; do
  clock a 1700000300.000000000 30000
  ( qr_config && qr_new_run '4444444444444444' synthetic ) || exit 1
  run "$a" perf start
  inaccessible_dir="$run_dir"
  guard="$inaccessible_dir/${key_a##*/}.armed"
  original_owner="$(jq -er .owner "$key_a")" || exit 1
  check "$interruption fixture starts with a committed window" '[ "$rc" = 0 ] && [ -s "$guard" ]'
  ( qr_config && qr_new_run '5555555555555555' synthetic ) || exit 1
  : > "$tmp/a.offline"
  : > "$tmp/events"
  clock a 1700000302.000000000 32000
  if [ "$interruption" = stop ]; then
    chmod 000 "$inaccessible_dir" || exit 1
    rc=0; QUEST_SERIAL="$a" "${permission_shell[@]}" "$0" --worker stop > "$tmp/out" 2>&1 || rc=$?
    report="$(. "$QUEST_LOG_ROOT/current.env" && printf '%s' "$QR_RUN_DIR")/perf-summary.json"
    check 'offline stop from another run reports INFRA' '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0'\'''
  else
    chmod 400 "$guard" && chmod 500 "$inaccessible_dir" || exit 1
    cancel stop stop-journal
    check 'offline cancellation drains the journaled stop before recovery' \
      '[ "$rc" = 1 ] && [ -e "$tmp/blocker.terminated" ] && grep -q "retry perf stop" "$tmp/out"'
  fi
  chmod 700 "$inaccessible_dir" && chmod 600 "$guard" || exit 1
  check "$interruption invalidates the reservation without losing restoration ownership" \
    '[ -s "$guard" ] && jq -e --arg owner "$original_owner" --arg dir "$inaccessible_dir" '\''.owner == $owner and .dir == $dir and (has("start") | not)'\'' "$key_a" >/dev/null && [ -e "$tmp/a.override" ] && grep -q "automation_disable" "$tmp/events" && ! grep -q "logcat" "$tmp/events"'
  rm -f "$tmp/a.offline"
  : > "$tmp/events"
  clock a 1700000304.000000000 34000
  {
    sample 1700000300.500000 'App=5ms'; sample 1700000301.500000 'App=5ms'
    sample 1700000302.500000 'App=5ms'; sample 1700000303.500000 'App=5ms'
  } > "$tmp/a.samples"
  run "$a" perf stop
  check "retry after $interruption restores only and requires a fresh capture despite passing post-stop samples" \
    '[ "$rc" = 3 ] && json '\''.overall == "INFRA" and .samples == 0 and (.message | contains("stop boundary unknown") and contains("fresh perf start"))'\'' && ! grep -Eq "shell date|logcat" "$tmp/events" && [ ! -e "$key_a" ] && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/unlocked-restore" ]'
done
# A directory at the root report path defeats rm -f even as root, without
# blocking the per-device reports or the reservation cleanup.
list="$a,$b"
clock a 1700000200.000000000 8000
clock b 1700000200.000000000 8000
rc=0; QUEST_SERIAL="$list" bash "$0" --worker start > "$tmp/out" 2>&1 || rc=$?
check 'list start succeeds before the root report is obstructed' \
  '[ "$rc" = 0 ] && [ -f "$key_a" ] && [ -f "$key_b" ] && [ -f "$tmp/a.override" ] && [ -f "$tmp/b.override" ]'
mkdir "$run_dir/perf-summary.json" || exit 1
for id in a b; do
  { sample 1700000200.500000 'App=5ms'; sample 1700000201.500000 'App=6ms'; } > "$tmp/$id.samples"
  clock "$id" 1700000202.000000000 10000
done
rc=0; QUEST_SERIAL="$list" bash "$0" --worker stop > "$tmp/out" 2>&1 || rc=$?
check 'obstructed root report leaves infrastructure status but stops both captures' \
  '[ "$rc" = 3 ] && [ -d "$run_dir/perf-summary.json" ] && grep -q "INFRA: cannot remove previous single-device performance reports" "$run_dir/summary.txt" && json '\''.overall == "PASS"'\'' "$run_dir/devices/$a_path/perf-summary.json" && json '\''.overall == "PASS"'\'' "$run_dir/devices/$b_path/perf-summary.json" && [ ! -e "$key_a" ] && [ ! -e "$key_b" ] && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/b.override" ] && [ ! -e "$tmp/unlocked-restore" ]'
rmdir "$run_dir/perf-summary.json" || exit 1
rc=0; QUEST_SERIAL="$list" bash "$0" --worker stop > "$tmp/out" 2>&1 || rc=$?
check 'retry cannot reuse either consumed capture' \
  '[ "$rc" = 3 ] && [ "$(grep -c "no matching perf start" "$run_dir/summary.txt")" = 2 ]'
clock a 1700000200.000000000 8000
clock b 1700000200.000000000 8000
rc=0; QUEST_SERIAL="$list" bash "$0" --worker start > "$tmp/out" 2>&1 || rc=$?
check 'a fresh start can reserve the same device list' '[ "$rc" = 0 ]'
clock a 1700000202.000000000 10000
clock b 1700000202.000000000 10000
rc=0; QUEST_SERIAL="$list" bash "$0" --worker stop > "$tmp/out" 2>&1 || rc=$?
check 'the same list stop succeeds with fresh windows after clearing the obstruction' \
  '[ "$rc" = 0 ] && [ ! -e "$key_a" ] && [ ! -e "$key_b" ] && [ ! -e "$tmp/a.override" ] && [ ! -e "$tmp/b.override" ]'
[ "$fails" = 0 ] || exit 1
echo 'all passed'
