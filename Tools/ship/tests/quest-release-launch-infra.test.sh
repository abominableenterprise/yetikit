#!/usr/bin/env bash
# Synthetic launch failures must not downgrade a healthy installed build.
# shellcheck disable=SC2016 # check evaluates conditions in the fixture's scope.
set -u
. "$(dirname "$0")/../quest-release.sh"
. "$(dirname "$0")/lib/quest-release-config.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
qr_test_config "$tmp/config"
export QUEST_REPO="$tmp" QUEST_WT_ROOT="$tmp/wt" QUEST_BACKUP_ROOT="$tmp" QUEST_SERIAL=synthetic-device
export QR_LAUNCH_WAIT=1 QR_ADB_WAIT=1 QUEST_WAIT_GRACE=0
mkdir -p "$tmp/wt"
printf 'new\n' > "$tmp/new.apk"; printf 'old\n' > "$tmp/old.apk"

# Replace only build/verification/data work: exercise real main/all/launch/rollback,
# the device await, idle parser and result publication. No editor or device runs.
qr_java_setup() { :; }
qr_keystore_preflight() { :; }
qr_prepare() { qr_new_run abc123456 origin/main; qr_set commit abc123456; }
qr_parallel_unity() { QR_GATE_RC=0; QR_BUILD_RC=0; qr_set apk "$tmp/new.apk"; }
qr_verify() { :; }
qr_backup() { printf '%s\n' "$tmp/backup"; }
qr_cleanup() { :; }
qr_apk_commit() { printf 'abc123456\n'; }
qr_timestamp() { printf '20990101-000001\n'; }
sleep() { :; } # Launch waits only; the fake wait-for-device returns immediately.
QR_DATA_FILES=''
qr_config_base="$(declare -f qr_config)"
eval "${qr_config_base/qr_config ()/qr_fixture_config ()}"
qr_config() { qr_fixture_config; QR_DATA_FILES=''; }

adb() {
  [ "$1" = -s ] && [ "$2" = "$QUEST_SERIAL" ] || return 99
  shift 2
  printf '%s\n' "$*" >> "$tmp/adb.log"
  case "$1" in
    get-state)
      if [ "$fault" = disconnect ] && [ -f "$tmp/installed" ]; then echo offline; return 1; fi
      echo device ;;
    wait-for-device) return 1 ;;
    install) printf '%s\n' "$*" >> "$tmp/installed"; echo Success ;;
    logcat)
      [ "$fault" != "logcat-$2" ] || { echo 'transport error' >&2; return 1; }
      if [ "$2" = -d ] && [ "$fault" = fatal ]; then
        echo '10-31 12:00:40.000 4242 4242 E AndroidRuntime: FATAL EXCEPTION: main'
      fi ;;
    shell)
      shift
      case "$*" in
        'getprop ro.product.manufacturer')
          if [ -f "$tmp/installed" ]; then
            [ "$fault" != maker ] || { echo other; return; }
            [ "$fault" != maker-transport ] || { echo Oculus; return 1; }
          fi
          echo Oculus ;;
        'am start '*)
          [ "$fault" != start ] || return 1
          [ "$fault" != start-output ] || echo 'Error: Activity not started, unable to resolve Intent' ;;
        'pidof '*)
          # Exercise the actual remote command (including its status trailer),
          # or return an adb transport failure, even with misleading stdout.
          if [ "$fault" = pidof-transport ]; then echo 4242; return 1; fi
          if [ "$fault" = pidof-final ] && [ -f "$tmp/probed" ]; then return 1; fi
          if [ "$fault" = pidof-malformed ]; then echo invalid; return 0; fi
          : > "$tmp/probed"
          ( pidof() { case "$fault" in gone|start-output) return 1 ;; esac; echo 4242; }; eval "$*" ) ;;
        'dumpsys activity activities'|'dumpsys window windows'|'dumpsys power'|'dumpsys vrpowermanager')
          if [ "$busy" = 1 ] && [ -f "$tmp/installed" ]; then
            fixture=game-mounted
          else fixture=home-multi-top-resumed; fi
          command cat "$(dirname "$0")/fixtures/quest-idle/$fixture.txt" ;;
        'getprop sys.hmt.mounted') : ;;
        'dumpsys package '*) : ;;
        *) return 99 ;;
      esac ;;
    *) return 99 ;;
  esac
}

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
run() {
  rm -rf "$tmp/wt/release-logs"
  rm -f "$tmp/installed" "$tmp/probed" "$tmp/adb.log"
  rc=0; ( qr_main "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  summary="$(find "$tmp/wt/release-logs" -name summary.txt | head -n1)"
}
no_rollback() { [ "$(wc -l < "$tmp/installed")" = 1 ] && ! grep -q 'install -r -d' "$tmp/adb.log"; }
infra() { [ "$rc" = 3 ] && grep -q '^launch:      INFRA:' "$summary"; }
fault=healthy busy=0
for fault in logcat--d logcat--c start start-output pidof-transport pidof-final pidof-malformed disconnect maker maker-transport; do
  run all --rollback "$tmp/old.apk"
  check "all $fault is INFRA, never rollback" 'infra && no_rollback && grep -q "launch could not be verified (infrastructure): not rolling back" "$tmp/err"'
  wrc=0; ( qr_main wait 0 ) > "$tmp/wait.out" 2>&1 || wrc=$?
  check "wait reports $fault as INFRA and fails" '[ "$wrc" = 1 ] && grep -q "launch:      INFRA:" "$tmp/wait.out"'
done
for fault in fatal gone; do
  run all --rollback "$tmp/old.apk"
  check "all $fault is a confirmed CRASH and rolls back" '[ "$rc" = 1 ] && grep -q "^launch:      CRASH:" "$summary" && grep -q "install -r -d $tmp/old.apk" "$tmp/installed"'
done
fault=fatal busy=1
run all --rollback "$tmp/old.apk"
check 'crash rollback respects idle check without user force' '[ "$rc" = 1 ] && no_rollback && grep -q "headset in use" "$tmp/err" && grep -q "IN USE.*refused" "$summary"'
run all --force --rollback "$tmp/old.apk"
check 'user force is forwarded to crash rollback' '[ "$rc" = 1 ] && grep -q "install -r -d $tmp/old.apk" "$tmp/installed" && grep -q "IN USE.*--force given" "$summary"'
fault=healthy busy=0
run all --rollback "$tmp/old.apk"
check 'healthy all launch remains successful, no rollback' '[ "$rc" = 0 ] && no_rollback && grep -q "^launch:      fps .*alive yes" "$summary"'
for fault in healthy gone pidof-transport logcat--d; do
  run launch
  case "$fault" in healthy) expected=0 ;; gone) expected=1 ;; *) expected=3 ;; esac
  check "standalone launch $fault exit code is $expected" '[ "$rc" = "$expected" ]'
done
# No implicit discovery failure may leave a stale successful launch result.
fault=healthy
adb_discovery() { return 1; }
rc=0; ( QUEST_SERIAL=''; adb() { adb_discovery; }; qr_main launch ) > "$tmp/out" 2> "$tmp/err" || rc=$?
check 'standalone device discovery failure is INFRA' '[ "$rc" = 3 ] && grep -q "^launch:      INFRA:" "$summary"'

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
