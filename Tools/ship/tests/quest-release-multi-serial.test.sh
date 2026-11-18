#!/usr/bin/env bash
# Multi-headset releases use one build and isolated, ordered device operations.
# All payloads, serials and adb responses are synthetic; no editor/device runs.
# shellcheck disable=SC2016 # check evaluates assertions in the fixture's scope.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release.sh"
. "$here/lib/quest-release-config.sh"
tmp="$(mktemp -d)"; lock_owner=''
cleanup() {
  if [ -n "$lock_owner" ]; then
    kill -TERM "$lock_owner" 2>/dev/null || true
    wait "$lock_owner" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
qr_test_config "$tmp/config"
jq '.quest.launcherChecks.permissions = ["android.permission.CAMERA"]' "$YETIKIT_CONFIG" > "$tmp/permissions.json"
YETIKIT_CONFIG="$tmp/permissions.json"
export QUEST_REPO="$tmp" QUEST_WT_ROOT="$tmp/wt" QUEST_BACKUP_ROOT="$tmp"
export QUEST_LOG_ROOT="$tmp/wt/release-logs" QUEST_APK_DIR="$tmp/apks"
export QR_LAUNCH_WAIT=1 QR_ADB_WAIT=1 QUEST_WAIT_GRACE=0
# Unique synthetic identifiers keep real headset locks independent of other tests.
token="${tmp##*/}"; token="$(printf '%s' "${token//./-}" | LC_ALL=C tr 'A-Z' 'a-z')"
a="synthetic-a_$token"; b="synthetic-b_$token"
case_peer="synthetic-A_$token"
wifi="synthetic.wifi-$token:5555"
escaped="synthetic%2Ewifi-$token%3A5555"
wifi_safe="synthetic%2Ewifi-$token%3A5555"
escaped_safe="synthetic%252%45wifi-$token%253%415555"
mkdir -p "$tmp/wt"
printf 'new\n' > "$tmp/new.apk"; printf 'old\n' > "$tmp/old.apk"

# Replace only host build/verification/data work. Leave main/all, selection,
# dispatch, run/headset locks, idle parsing, install, launch, rollback and wait real.
qr_java_setup() { [ "${host_fault:-}" != java ] || qr_die 'synthetic Java failure'; }
qr_keystore_preflight() { [ "${host_fault:-}" != keystore ] || qr_die 'synthetic keystore failure'; }
qr_prepare() {
  echo prepare >> "$tmp/steps"
  rm -f "$(qr_state_file)"
  [ "${host_fault:-}" != prepare ] || qr_die 'synthetic prepare failure'
  if [ "${host_fault:-}" = worktree ]; then
    qr_new_run abc123456 origin/main pending
    qr_lock_note_run
    qr_die 'synthetic worktree failure after assigning the run folder'
  fi
  qr_new_run abc123456 origin/main
  qr_set commit abc123456
  if [ "${host_fault:-}" = device-dir ]; then
    mkdir -p "$QR_RUN_DIR/devices"
    : > "$QR_RUN_DIR/devices/$(qr_serial_path "$b")"
  fi
}
qr_parallel_unity() {
  echo build >> "$tmp/steps"
  QR_GATE_RC=0; QR_BUILD_RC=0
  case "${host_fault:-}" in gate) QR_GATE_RC=1 ;; build) QR_BUILD_RC=1 ;; esac
  qr_set gate 'passed'; qr_set gate_result passed
  if [ "${host_fault:-}" = verify ]; then qr_set apk "$tmp/missing.apk"
  else qr_set apk "$tmp/new.apk"; fi
}
qr_verify_base="$(declare -f qr_verify)"
eval "${qr_verify_base/qr_verify ()/qr_fixture_real_verify ()}"
qr_verify() {
  printf 'verify %s\n' "${1##*/}" >> "$tmp/steps"
  if [ -f "$1" ]; then command cat "$1" >> "$tmp/verified-bytes"; fi
  # Exercise the production early missing-file failure, without SDK/device work.
  [ -f "$1" ] || qr_fixture_real_verify "$@"
  qr_set apk "${2:-$1}"
}
qr_backup() { printf '%s\n' "$tmp/backup-$QUEST_SERIAL"; }
qr_cleanup() { echo cleanup >> "$tmp/steps"; }
qr_apk_commit() {
  case "$(command cat "$1")" in new) echo aaaaaaaaa ;; old) echo fffffffff ;; esac
}
qr_timestamp() { printf '20990101-000001\n'; }
sleep() {
  # Skip the launch observation delay, not lock registration/draining sleeps.
  if [ "$1" = 1 ]; then :; else command sleep "$@"; fi
}
qr_config_base="$(declare -f qr_config)"
eval "${qr_config_base/qr_config ()/qr_fixture_config ()}"
qr_config() { qr_fixture_config || return; QR_DATA_FILES=''; }

# Fake state is keyed by a fixed fixture ID, never the current list string.
# Unknown/list-valued -s arguments fail closed instead of contacting real adb.
fixture_id() {
  case "$1" in
    "$a") echo a ;; "$b") echo b ;; "$wifi") echo wifi ;; "$escaped") echo escaped ;; "$case_peer") echo peer ;;
    *) return 99 ;;
  esac
}
adb() {
  local serial id state fault fixture fps
  [ "${1:-}" = -s ] && [ "$#" -ge 3 ] || return 99
  serial="$2"; shift 2
  id="$(fixture_id "$serial")" || return 99
  state="$tmp/state/$id"
  fault="$(command cat "$state/fault")"
  printf '%s|%s\n' "$serial" "$*" >> "$tmp/adb.log"
  printf '%s\n' "$*" >> "$state/adb.log"
  case "$1" in
    get-state) echo device ;;
    wait-for-device) return 1 ;;
    install)
      [ "$fault" != install ] || { echo 'synthetic transport failure' >&2; return 1; }
      command cat "${@: -1}" >> "$state/installed-bytes" || return 99
      printf '%s\n' "$*" >> "$state/installed"
      if [ "$id" = a ] && [ "${replace_apks:-0}" = 1 ] && [ ! -f "$tmp/replaced" ]; then
        local name
        for name in new old; do
          printf 'replacement\n' > "$tmp/$name.next" && mv -f "$tmp/$name.next" "$tmp/$name.apk" || return 99
        done
        : > "$tmp/replaced"
      fi
      echo Success ;;
    logcat)
      if [ "$2" = -d ]; then
        [ "$fault" != infra ] || { echo 'synthetic transport failure' >&2; return 1; }
        if [ "$fault" = blocked ]; then
          echo 'SystemUXController: Launch is blocked because: a Reprojected OS dialog is currently showing. Caching launch for component com.example.consumer/com.unity3d.player.UnityPlayerGameActivity'
        elif [ "$fault" = never-started ]; then
          :
        elif [ "$fault" = crash ]; then
          echo '10-31 12:00:40.000 4242 4242 E AndroidRuntime: FATAL EXCEPTION: main'
        else
          case "$id" in a) fps=71 ;; b) fps=72 ;; wifi) fps=73 ;; escaped) fps=74 ;; peer) fps=75 ;; esac
          printf '10-31 12:00:40.000 4242 4242 I Unity: [SyntheticPerf] fps=%s\n' "$fps"
        fi
      fi ;;
    shell)
      shift
      case "$*" in
        'getprop ro.product.manufacturer') echo Oculus ;;
        'am start '*) : > "$state/launched" ;;
        'pidof '*)
          # Execute the real remote probe including its status trailer.
          ( pidof() { case "$fault" in blocked|never-started) return 1 ;; esac; echo 4242; }; eval "$*" ) ;;
        'dumpsys activity activities'|'dumpsys window windows'|'dumpsys power'|'dumpsys vrpowermanager')
          fixture=home-multi-top-resumed
          [ ! -f "$state/busy" ] || fixture=game-mounted
          command cat "$here/fixtures/quest-idle/$fixture.txt" ;;
        'getprop sys.hmt.mounted') : ;;
        'am get-current-user') if [ "$id" = a ]; then echo 0; else echo 10; fi ;;
        'dumpsys package '*)
          printf '%s\n' 'Packages:' "  Package [$3] (abcd):" \
            '    User 0: installed=true hidden=false' '      runtime permissions:' \
            '        android.permission.CAMERA: granted=true' \
            '    User 10: installed=true hidden=false' '      runtime permissions:' \
            '        android.permission.CAMERA: granted=false' ;;
        *) return 99 ;;
      esac ;;
    *) return 99 ;;
  esac
}

fails=0
check() {
  if eval "$2"; then echo "ok   $1"
  else
    echo "FAIL $1"; fails=$((fails + 1))
    [ ! -f "$tmp/err" ] || tail -n 8 "$tmp/err"
    [ ! -f "${summary:-}" ] || command cat "$summary"
  fi
}
reset_case() {
  rm -rf "$QUEST_LOG_ROOT" "$tmp/state"
  mkdir -p "$tmp/state"
  local id
  host_fault=''
  for id in a b wifi escaped peer; do
    mkdir -p "$tmp/state/$id"
    echo healthy > "$tmp/state/$id/fault"
  done
  replace_apks=0; rm -f "$tmp/replaced"
  printf 'new\n' > "$tmp/new.apk"; printf 'old\n' > "$tmp/old.apk"
  : > "$tmp/steps"; : > "$tmp/adb.log"; : > "$tmp/verified-bytes"
}
run() {
  QUEST_SERIAL="$1"; export QUEST_SERIAL; shift
  rc=0; ( qr_main "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  run_dir="$(
    [ -f "$QUEST_LOG_ROOT/current.env" ] || exit 0
    . "$QUEST_LOG_ROOT/current.env"
    printf '%s\n' "$QR_RUN_DIR"
  )"
  summary="$run_dir/summary.txt"
}
# Public summary contract: allow padding/details, but require the exact serial
# and outcome, so neither stale global success nor another device can mask it.
result_is() {
  [ -f "$summary" ] && grep -Eq "^$1\\[$2\\]:[[:space:]]+$3([[:space:]:,]|$)" "$summary"
}
# Serial IDs above contain no regexp characters; Wi-Fi assertions use fixed text.
no_rollback() { ! grep -q '^install -r -d ' "$tmp/state/$1/adb.log" 2>/dev/null; }
installed_once() { [ -f "$tmp/state/$1/installed" ] && [ "$(wc -l < "$tmp/state/$1/installed")" -eq 1 ]; }
rolled_back() { grep -Eq '^install -r -d .*/old\.apk$' "$tmp/state/$1/installed"; }
wait_run() {
  wrc=0; ( qr_main wait 0 ) > "$tmp/wait.out" 2>&1 || wrc=$?
}
wait_result_is() {
  grep -Eq "^$1\\[$2\\]:[[:space:]]+$3([[:space:]:,]|$)" "$tmp/wait.out"
}

reset_case
run "$a,$b" all --rollback "$tmp/old.apk"
check 'healthy comma list builds and verifies the new APK exactly once' \
  '[ "$rc" = 0 ] && [ "$(grep -c "^prepare$" "$tmp/steps")" = 1 ] && [ "$(grep -c "^build$" "$tmp/steps")" = 1 ] && [ "$(grep -Fxc "verify new.apk" "$tmp/steps")" = 1 ]'
check 'healthy devices install in input order, each exactly once, without rollback' \
  'installed_once a && installed_once b && no_rollback a && no_rollback b && [ "$(grep "|install " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "%s\n%s" "$a" "$b")" ]'
check 'each device completes launch before the next install begins' \
  '[ "$(grep -E "\\|install |\\|shell am start " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "%s\n%s\n%s\n%s" "$a" "$a" "$b" "$b")" ]'
check 'healthy summary retains both install and launch results' \
  'result_is install "$a" OK && result_is install "$b" OK && result_is launch "$a" OK && result_is launch "$b" OK'
check 'the summary shows the permission state for each device separately' \
  'grep -F "install[$a]:" "$summary" | grep -Fq "permissions: user 0: android.permission.CAMERA granted=true" &&
    grep -F "install[$b]:" "$summary" | grep -Fq "permissions: user 10: android.permission.CAMERA granted=false"'
check 'multi-device artifacts do not overwrite each other or use the single-device root' \
  '[ -s "$run_dir/devices/$a/install-adb.log" ] && [ -s "$run_dir/devices/$b/install-adb.log" ] && [ -s "$run_dir/devices/$a/launch-report.txt" ] && [ -s "$run_dir/devices/$b/launch-report.txt" ] && [ ! -e "$run_dir/install-adb.log" ] && [ ! -e "$run_dir/launch-report.txt" ]'
check 'each logcat capture belongs to its selected device' \
  'grep -Fq "fps=71" "$run_dir/devices/$a/launch-logcat.txt" && ! grep -Fq "fps=72" "$run_dir/devices/$a/launch-logcat.txt" && grep -Fq "fps=72" "$run_dir/devices/$b/launch-logcat.txt" && ! grep -Fq "fps=71" "$run_dir/devices/$b/launch-logcat.txt"'
wait_run
check 'wait succeeds and prints both healthy devices' \
  '[ "$wrc" = 0 ] && wait_result_is install "$a" OK && wait_result_is install "$b" OK && wait_result_is launch "$a" OK && wait_result_is launch "$b" OK'

for fault_case in blocked never-started; do
  reset_case
  echo "$fault_case" > "$tmp/state/b/fault"
  run "$a $b" all --rollback "$tmp/old.apk"
  case "$fault_case" in
    blocked) reason='launch blocked by the OS: a Reprojected OS dialog is currently showing' ;;
    never-started) reason='process never started (no crash evidence)' ;;
  esac
  check "multi $fault_case retains INFRA reason without rollback" \
    '[ "$rc" = 3 ] && result_is launch "$a" OK && result_is launch "$b" INFRA && no_rollback a && no_rollback b && grep -Fq "$reason" "$summary"'
  wait_run
  check "multi wait retains $fault_case reason" \
    '[ "$wrc" = 1 ] && wait_result_is launch "$b" INFRA && grep -Fq "$reason" "$tmp/wait.out"'
done

reset_case
echo crash > "$tmp/state/b/fault"
run "$a $b" all --rollback "$tmp/old.apk"
check 'B crash fails all and rolls back only B, leaving A healthy' \
  '[ "$rc" = 1 ] && installed_once a && no_rollback a && rolled_back b && [ "$(wc -l < "$tmp/state/b/installed")" -eq 2 ] && result_is launch "$a" OK && result_is launch "$b" CRASH && result_is rollback "$b" OK'
check 'primary and rollback APKs are each verified once, not once per device' \
  '[ "$(grep -Fxc "verify new.apk" "$tmp/steps")" = 1 ] && [ "$(grep -Fxc "verify old.apk" "$tmp/steps")" = 1 ]'
check 'B rollback has its own artifacts without overwriting B install or A files' \
  '[ -s "$run_dir/devices/$b/install-adb.log" ] && [ -s "$run_dir/devices/$b/rollback-adb.log" ] && [ ! -e "$run_dir/devices/$a/rollback-adb.log" ]'
wait_run
check 'wait fails after B crash even though rollback succeeded and A is healthy' \
  '[ "$wrc" = 1 ] && wait_result_is launch "$a" OK && wait_result_is launch "$b" CRASH && wait_result_is rollback "$b" OK'

reset_case
replace_apks=1
echo crash > "$tmp/state/b/fault"
run "$a,$b" all --rollback "$tmp/old.apk"
check 'list all installs the verified primary and rollback bytes after both source paths are replaced' \
  '[ "$rc" = 1 ] && [ -f "$tmp/replaced" ] && [ "$(command cat "$tmp/verified-bytes")" = "$(printf "new\nold")" ] &&
    [ "$(command cat "$tmp/state/a/installed-bytes")" = new ] &&
    [ "$(command cat "$tmp/state/b/installed-bytes")" = "$(printf "new\nold")" ] && result_is rollback "$b" OK'

for operation in install rollback; do
  reset_case
  replace_apks=1
  if [ "$operation" = install ]; then payload=new; else payload=old; fi
  run "$a,$b" "$operation" "$tmp/$payload.apk"
  check "standalone list $operation keeps installing verified bytes after source replacement" \
    '[ "$rc" = 0 ] && [ -f "$tmp/replaced" ] && [ "$(command cat "$tmp/verified-bytes")" = "$payload" ] &&
      cmp -s "$tmp/state/a/installed-bytes" "$tmp/verified-bytes" && cmp -s "$tmp/state/b/installed-bytes" "$tmp/verified-bytes" &&
      [ "$(command cat "$run_dir/summary/apk")" = "$tmp/$payload.apk" ] && [ ! -e "$QUEST_LOG_ROOT/run.lock" ]'
done

reset_case
echo infra > "$tmp/state/b/fault"
run "$a,$b" all --rollback "$tmp/old.apk"
check 'B launch infrastructure failure never authorizes rollback on either device' \
  '[ "$rc" = 3 ] && installed_once a && installed_once b && no_rollback a && no_rollback b && result_is launch "$a" OK && result_is launch "$b" INFRA'
wait_run
check 'wait fails and identifies B infrastructure failure without hiding A success' \
  '[ "$wrc" = 1 ] && wait_result_is launch "$a" OK && wait_result_is launch "$b" INFRA'

reset_case
: > "$tmp/state/a/busy"
run "$a,$b" all --rollback "$tmp/old.apk"
check 'busy A refuses install, but B still installs and launches' \
  '[ "$rc" = 3 ] && [ ! -f "$tmp/state/a/installed" ] && [ ! -f "$tmp/state/a/launched" ] && installed_once b && [ -f "$tmp/state/b/launched" ] && no_rollback a && no_rollback b && result_is install "$a" INFRA && result_is install "$b" OK && result_is launch "$b" OK && grep -q "headset in use" "$tmp/err"'
wait_run
check 'wait fails for A busy refusal even when the last device succeeds' \
  '[ "$wrc" = 1 ] && wait_result_is install "$a" INFRA && wait_result_is launch "$b" OK'

# Hold A's real cross-consumer headset lock while the release runs. The holder
# has a separate log root and never substitutes lock primitives in the caller.
reset_case
mkdir -p "$tmp/lock-owner"
mkfifo "$tmp/lock-gate"; exec 8<> "$tmp/lock-gate"
(
  QUEST_SERIAL="$a"; QR_LOGS="$tmp/lock-owner"
  hold_device() {
    : > "$tmp/lock-ready"
    read -r -t 15 _ <&8 || true
  }
  qr_device_locked hold_device
) > "$tmp/holder.out" 2>&1 &
lock_owner=$!
ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$tmp/lock-ready" ]; then ready=1; break; fi
  kill -0 "$lock_owner" 2>/dev/null || break
  command sleep 0.1
done
run "$a,$b" all --rollback "$tmp/old.apk"
check 'A device-lock refusal is INFRA while B continues normally' \
  '[ "$ready" = 1 ] && [ "$rc" = 3 ] && [ ! -f "$tmp/state/a/installed" ] && installed_once b && [ -f "$tmp/state/b/launched" ] && no_rollback a && no_rollback b && result_is install "$a" INFRA && result_is launch "$b" OK && grep -q "another quest-release run is active" "$tmp/err"'
printf 'release\n' >&8
wait "$lock_owner" || true
lock_owner=''; exec 8>&-

# Mixed outcomes must reduce by severity, not first failure or last device.
for crash_id in a b; do
  reset_case
  if [ "$crash_id" = a ]; then infra_id=b; else infra_id=a; fi
  echo crash > "$tmp/state/$crash_id/fault"
  echo infra > "$tmp/state/$infra_id/fault"
  run "$a,$b" all --rollback "$tmp/old.apk"
  check "crash outranks infrastructure with crash on $crash_id" \
    '[ "$rc" = 1 ] && rolled_back "$crash_id" && no_rollback "$infra_id" && [ -f "$tmp/state/a/launched" ] && [ -f "$tmp/state/b/launched" ]'
  if [ "$crash_id" = a ]; then
    check 'A crash rollback completes before B begins its install' \
      '[ "$(grep -E "\\|install |\\|shell am start " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "%s\n%s\n%s\n%s\n%s" "$a" "$a" "$a" "$b" "$b")" ]'
  fi
done

reset_case
# Include padding, comma, tab and newline separators in the same list.
run "  $wifi,  $escaped"$'\t\n'"$a  " all
check 'Wi-Fi serial and an escaped-looking serial remain distinct adb targets' \
  '[ "$rc" = 0 ] && installed_once wifi && installed_once escaped && installed_once a && [ "$(grep "|install " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "%s\n%s\n%s" "$wifi" "$escaped" "$a")" ]'
check 'folder encoding escapes dots, colon and percent without collisions; underscore/hyphen stay literal' \
  '[ "$wifi_safe" != "$escaped_safe" ] && [ -s "$run_dir/devices/$wifi_safe/launch-report.txt" ] && [ -s "$run_dir/devices/$escaped_safe/launch-report.txt" ] && [ -s "$run_dir/devices/$a/launch-report.txt" ] && [ ! -e "$run_dir/devices/$wifi" ]'
check 'Wi-Fi summary uses raw serial rather than its encoded folder name' \
  'grep -Fq "launch[$wifi]:" "$summary" && grep -Fq "install[$wifi]:" "$summary"'

# Standalone commands must use the same list expansion and aggregation as all.
reset_case
run "$b $a" install "$tmp/new.apk"
check 'standalone install accepts whitespace list and honors its order' \
  '[ "$rc" = 0 ] && installed_once a && installed_once b && result_is install "$a" OK && result_is install "$b" OK && [ "$(grep "|install " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "%s\n%s" "$b" "$a")" ]'
wait_run
check 'wait succeeds for standalone list install with per-device output' \
  '[ "$wrc" = 0 ] && wait_result_is install "$a" OK && wait_result_is install "$b" OK'

reset_case
echo install > "$tmp/state/a/fault"
run "$a,$b" install "$tmp/new.apk"
check 'standalone failed install is INFRA and does not stop the next device' \
  '[ "$rc" = 3 ] && [ ! -f "$tmp/state/a/installed" ] && installed_once b && result_is install "$a" INFRA && result_is install "$b" OK'
wait_run
check 'wait fails on standalone list install partial failure' \
  '[ "$wrc" = 1 ] && wait_result_is install "$a" INFRA && wait_result_is install "$b" OK'

reset_case
run "$a,$b" launch
check 'standalone launch accepts comma list and reports both successes' \
  '[ "$rc" = 0 ] && [ -f "$tmp/state/a/launched" ] && [ -f "$tmp/state/b/launched" ] && result_is launch "$a" OK && result_is launch "$b" OK'
wait_run
check 'wait succeeds for standalone list launch' \
  '[ "$wrc" = 0 ] && wait_result_is launch "$a" OK && wait_result_is launch "$b" OK'
for crash_id in a b; do
  reset_case
  if [ "$crash_id" = a ]; then infra_id=b; else infra_id=a; fi
  echo crash > "$tmp/state/$crash_id/fault"
  echo infra > "$tmp/state/$infra_id/fault"
  run "$a $b" launch
  check "standalone launch crash outranks infra with crash on $crash_id" \
    '[ "$rc" = 1 ] && [ -f "$tmp/state/a/launched" ] && [ -f "$tmp/state/b/launched" ] && no_rollback a && no_rollback b'
done

reset_case
run "$b,"$'\t'"$a" rollback "$tmp/old.apk"
check 'standalone rollback accepts mixed separators and targets both devices in order' \
  '[ "$rc" = 0 ] && rolled_back a && rolled_back b && installed_once a && installed_once b && result_is rollback "$a" OK && result_is rollback "$b" OK && [ "$(grep "|install " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "%s\n%s" "$b" "$a")" ]'
wait_run
check 'wait succeeds for standalone list rollback with per-device output' \
  '[ "$wrc" = 0 ] && wait_result_is rollback "$a" OK && wait_result_is rollback "$b" OK'
reset_case
echo install > "$tmp/state/b/fault"
run "$a,$b" rollback "$tmp/old.apk"
check 'standalone rollback partial failure is INFRA without hiding A success' \
  '[ "$rc" = 3 ] && rolled_back a && [ ! -f "$tmp/state/b/installed" ] && result_is rollback "$a" OK && result_is rollback "$b" INFRA'
wait_run
check 'wait fails on standalone list rollback partial failure' \
  '[ "$wrc" = 1 ] && wait_result_is rollback "$a" OK && wait_result_is rollback "$b" INFRA'

reset_case
run "$a" all --rollback "$tmp/old.apk"
check 'single serial keeps its original artifact layout and summary format' \
  '[ "$rc" = 0 ] && installed_once a && no_rollback a && [ -s "$run_dir/install-adb.log" ] && [ -s "$run_dir/launch-report.txt" ] && [ ! -e "$run_dir/devices" ] && grep -q "^install: *install ok" "$summary" && grep -q "^launch: *fps .*alive yes" "$summary"'
wait_run
check 'single-serial wait remains successful' '[ "$wrc" = 0 ]'

# Reusing a single-device run must not let a pre-device list verification
# failure advertise the earlier install/launch successes. No adb work may start.
for operation in install rollback; do
  reset_case
  run "$a" all
  check "seed single-device success before list $operation verification failure" \
    '[ "$rc" = 0 ] && grep -q "^install: *install ok" "$summary" && grep -q "^launch: *fps .*alive yes" "$summary"'
  old_run="$run_dir"
  : > "$tmp/adb.log"
  run "$a,$b" "$operation" "$tmp/missing.apk"
  check "list $operation verification failure replaces stale root successes" \
    '[ "$rc" = 3 ] && [ "$run_dir" = "$old_run" ] && [ ! -s "$tmp/adb.log" ] && ! grep -Eq "^install: *install ok|^launch: *fps .*alive yes" "$summary" && grep -q "^overall: *INFRA" "$summary" && [ -z "$(command cat "$run_dir/summary/device_results")" ]'
  wait_run
  check "wait exposes list $operation verification failure before any device rows" \
    '[ "$wrc" = 1 ] && grep -q "^overall: *INFRA" "$tmp/wait.out" && ! grep -Eq "^install: *install ok|^launch: *fps .*alive yes" "$tmp/wait.out"'
done

reset_case
run "$a,$case_peer" all
# Fold names as a case-insensitive filesystem would, even on Linux.
peer_path="$(qr_serial_path "$case_peer")"
check 'case-only serials have distinct paths after ASCII case folding and keep separate logs' \
  '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$peer_path" | LC_ALL=C tr "A-Z" "a-z")" != "$a" ] && grep -Fq "fps=71" "$run_dir/devices/$a/launch-logcat.txt" && grep -Fq "fps=75" "$run_dir/devices/$peer_path/launch-logcat.txt"'

reset_case
host_fault=device-dir
echo crash > "$tmp/state/a/fault"
run "$a,$b,$wifi" all --rollback "$tmp/old.apk"
check 'device-dir failure records infrastructure and continues without hiding an earlier crash' \
  '[ "$rc" = 1 ] && result_is launch "$a" CRASH && result_is install "$b" INFRA && [ ! -s "$tmp/state/b/adb.log" ] && installed_once wifi && grep -Fq "launch[$wifi]: OK" "$summary" && grep -q "^overall: *CRASH (exit 1)" "$summary"'
wait_run
check 'wait reports crash precedence after a device-dir failure' \
  '[ "$wrc" = 1 ] && wait_result_is launch "$a" CRASH && wait_result_is install "$b" INFRA && grep -q "^overall: *CRASH (exit 1)" "$tmp/wait.out"'

reset_case
echo install > "$tmp/state/a/fault"
run "$a,$b" install "$tmp/new.apk"
run "$b,$a" launch
check 'standalone launch retains the previous install results but has its own overall verdict' \
  '[ "$rc" = 0 ] && result_is install "$a" INFRA && result_is install "$b" OK && result_is launch "$a" OK && result_is launch "$b" OK && grep -q "^overall: *OK (exit 0)" "$summary"'
wait_run
check 'wait shows retained failed install without failing the successful launch' \
  '[ "$wrc" = 0 ] && wait_result_is install "$a" INFRA && wait_result_is launch "$a" OK'

reset_case
echo crash > "$tmp/state/a/fault"
run "$a,$b" all --rollback "$tmp/old.apk"
check 'equal-second rollback then primary installs select the last actual install, not the larger SHA' \
  '[ "$rc" = 1 ] && rolled_back a && installed_once b && cmp -s "$run_dir/devices/$a/summary/installed_at" "$run_dir/devices/$b/summary/installed_at" && [ "$(QR_LOGS="$QUEST_LOG_ROOT" qr_last_installed_sha)" = aaaaaaaaa ]'

reset_case
run "$a,$b" install "$tmp/new.apk"
run "$a,$b" rollback "$tmp/old.apk"
: > "$tmp/adb.log"
run "$a,$b" rollback
check 'missing rollback argument replaces the old rollback verdict without clearing install history' \
  '[ "$rc" = 3 ] && [ ! -s "$tmp/adb.log" ] && ! result_is rollback "$a" OK && ! result_is rollback "$b" OK && result_is install "$a" OK && result_is install "$b" OK && grep -q "^overall: *INFRA" "$summary"'
run "$a,$b" launch
check 'later launch cannot revive the stale rollback rows' \
  '[ "$rc" = 0 ] && ! result_is rollback "$a" OK && ! result_is rollback "$b" OK && result_is install "$a" OK'

for fault_case in args java prepare worktree keystore gate build verify; do
  reset_case
  run "$a,$b" install "$tmp/new.apk"
  : > "$tmp/adb.log"
  host_fault="$fault_case"
  if [ "$fault_case" = args ]; then run "$a,$b" all --rollback
  else run "$a,$b" all; fi
  check "list all $fault_case failure is fresh INFRA before any adb work" \
    '[ "$rc" = 3 ] && [ ! -s "$tmp/adb.log" ] && ! grep -Fq "install[$a]: OK" "$tmp/out" && grep -q "^overall: *INFRA" "$tmp/out"'
  if [ "$fault_case" = worktree ]; then
    check 'incomplete worktrees keep their own failure report without becoming current' \
      '[ ! -f "$QUEST_LOG_ROOT/current.env" ] && grep -q "^run=.*/abc123456-" "$QUEST_LOG_ROOT/last-result"'
  fi
  wait_run
  check "wait reports list all $fault_case failure with no stale install success" \
    '[ "$wrc" = 1 ] && ! wait_result_is install "$a" OK && grep -q "^overall: *INFRA" "$tmp/wait.out"'
done

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
