#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build

# --- launch ----------------------------------------------------------------------------------------------------------------------
FAKE_LOGCAT='10-31 12:00:01.000  4242  4260 I Unity   : synthetic diagnostic
10-31 12:00:30.000  4242  4260 I Unity   : [SyntheticPerf] fps=71.9 frame=13.9ms
10-31 12:00:31.000  4242  4260 W Unity   : [SyntheticFeature] voice model ready
10-31 12:00:32.000  4242  4260 E Unity   : NullReferenceException: boom
10-31 12:00:00.000  4100  4100 D AndroidRuntime: Calling main entry com.android.commands.am.Am'
reset_logs; run launch
check "launch: logcat -c, am start of the verified activity, one logcat -d, no polling" \
  '[ "$rc" = 0 ] && [ "$(grep -c "logcat -c" "$tmp/adb.log")" = 1 ] && [ "$(grep -c "logcat -d" "$tmp/adb.log")" = 1 ] && grep -q "am start -n com.example.consumer/com.unity3d.player.UnityPlayerGameActivity" "$tmp/adb.log"'
check "launch has no consumer-specific boot extras" \
  '! grep -q -- "--es" "$tmp/adb.log"'
check "launch reports configured fps and E/Unity lines and a live process" \
  'grep -q "launch:      fps 71.9.*E/Unity 1.*fatal 1.*alive yes" "$tmp/out" && out_has "NullReferenceException: boom"'
check "a healthy launch does not warn about the shell interstitial" '! out_has "WARN.*Quest shell"'
for broadcast in appLaunchFailureBroadcastReceived sendExtendedInterstitialBroadcast; do
  reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
11-01 12:00:30.000  1234  1234 I VrShell: $broadcast packageName=com.example.consumer resolution HEALTHY_INSTALLATION" run launch
  check "$broadcast for our package warns despite good fps and a live process (not a crash)" \
    '[ "$rc" = 0 ] && out_has "WARN: Quest shell" && out_has "$broadcast packageName" && grep -q "shell launch warnings 1" "$tmp/out" && ! grep -q "launch:      CRASH" "$tmp/out"'
  check "shell warning is saved in the launch report" \
    'grep -q "WARN: Quest shell" "$root"/release-logs/"$short"-*/launch-report.txt'
done
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
11-01 12:00:30.000  1234  1234 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.other
11-01 12:00:31.000  1234  1234 I VrShell: sendExtendedInterstitialBroadcast packageName=com.example.consumer.other
11-01 12:00:32.000  1234  1234 I VrShell: appLaunchFailureBroadcastReceived packageName=comXexampleXconsumer
11-01 12:00:33.000  1234  1234 I VrShell: launching com.example.consumer" run launch
check "other packages, package prefixes and unrelated package lines do not warn" \
  '[ "$rc" = 0 ] && ! out_has "WARN.*Quest shell" && ! out_has "shell launch warnings"'
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
11-01 12:00:30.000  1234  1234 I VrShell: sendExtendedInterstitialBroadcast packageName=com.example.consumer secondsSinceDetection=260
11-01 12:00:31.000  1234  1234 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.consumer resolution HEALTHY_INSTALLATION" run launch
check "both shell broadcasts are counted without converting them into a crash" \
  '[ "$rc" = 0 ] && out_has "shell launch warnings 2" && ! grep -q "launch:      CRASH" "$tmp/out"'

# Exercise the default 60 s path without waiting: the early snapshot can contain a broadcast which has rolled out
# by the final snapshot. Stub sleep only inside this subshell, leaving all other timebox tests real.
launch_timing() (
  local dumps=0
  sleep() {
    case "$1" in 0.*) command sleep "$1" ;; *) echo "$1" >> "$tmp/launch-sleeps" ;; esac
  }
  qr_adb() {
    if [ "${1:-}" = logcat ] && [ "${2:-}" = -d ]; then
      dumps=$((dumps + 1))
      echo "snapshot $dumps" >> "$tmp/launch-snapshots"
      if [ "$dumps" = 1 ] && [ "$QR_LAUNCH_WAIT" -gt 30 ]; then
        [ "${FAKE_EARLY_FAIL:-0}" = 0 ] || { echo 'adb unavailable'; return 1; }
        printf '%s\n' "$FAKE_LOGCAT"
        echo '11-01 12:00:30.000 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.consumer'
      else
        printf '%s\n' "$FAKE_LOGCAT"
      fi
    else
      adb -s "$serial" "$@"
    fi
  }
  qr_main launch
)
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=60 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "default wait checks at 30 s, then at 60 s, preserving early-only warnings" \
  '[ "$rc" = 0 ] && [ "$(paste -sd, "$tmp/launch-sleeps")" = 30,30 ] && [ "$(wc -l < "$tmp/launch-snapshots")" = 2 ] && out_has "30s check" && out_has "shell launch warnings 1"'
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=60 FAKE_EARLY_FAIL=1 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "early snapshot failure is infrastructure, not a crash" \
  '[ "$rc" = 3 ] && out_has "early adb logcat -d failed" && [ "$(wc -l < "$tmp/launch-snapshots")" = 1 ] && out_has "launch:      INFRA:"'
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=30 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "a 30 s wait uses one final snapshot without an additional delay" \
  '[ "$rc" = 0 ] && [ "$(paste -sd, "$tmp/launch-sleeps")" = 30 ] && [ "$(wc -l < "$tmp/launch-snapshots")" = 1 ]'
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
10-31 12:00:40.000  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main" run launch
check "a FATAL line is a crash (exit 1)" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
for unrelated in \
  '10-31 12:00:40.000  9999  9999 E AndroidRuntime: FATAL EXCEPTION: main' \
  'E/AndroidRuntime( 9999): FATAL EXCEPTION: main' \
  '10-31 12:00:40.000  9999  9999 F libc: Fatal signal 11 in tid 9999' \
  "10-31 12:00:40.000  9999  9999 F DEBUG: pid: 8888, tid: 8888, name: other >>> $QR_PKG.other <<<"; do
  reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
$unrelated" run launch
  check "unrelated crash remains diagnostic, not a launch failure: $unrelated" \
    '[ "$rc" = 0 ] && ! grep -q "launch:      CRASH" "$tmp/out"'
done
reset_logs; FAKE_LOGCAT='E/AndroidRuntime( 4242): FATAL EXCEPTION: main' run launch
check "brief-format game crash is scoped by PID" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_LOGCAT="10-31 12:00:40.000  9999  9999 F DEBUG: pid: 4242, tid: 4242, name: UnityMain >>> $QR_PKG <<<" run launch
check "native tombstone for the exact game package fails launch" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_LOGCAT="10-31 12:00:40.000  9998  9998 E AndroidRuntime: FATAL EXCEPTION: main
10-31 12:00:40.001  9998  9998 E AndroidRuntime: Process: $QR_PKG, PID: 9998" run launch
check "package attribution catches a game process that restarted during observation" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_ALIVE=0 run launch
check "a dead process is a crash" '[ "$rc" != 0 ] && grep -q "alive no" "$tmp/out"'


qr_flow_finish
