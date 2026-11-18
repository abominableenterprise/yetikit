#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build
qr_flow_healthy_log

# --- launch and shell diagnostics --------------------------------------------------------------------------------------
reset_logs; run launch
check "launch: logcat -c, am start of the verified activity, one logcat -d, no polling" \
  '[ "$rc" = 0 ] && [ "$(grep -c "logcat -c" "$tmp/adb.log")" = 1 ] && [ "$(grep -c "logcat -d" "$tmp/adb.log")" = 1 ] && grep -q "am start -n com.example.consumer/com.unity3d.player.UnityPlayerGameActivity" "$tmp/adb.log"'
check "launch has no consumer-specific boot extras" \
  '! grep -q -- "--es" "$tmp/adb.log"'
check "launch reports configured fps and E/Unity lines and a live process" \
  'grep -q "launch:      fps 71.9.*E/Unity 1.*fatal 1.*alive yes" "$tmp/out" && out_has "NullReferenceException: boom"'
check "launch emits no tag counts when quest.launchLogTags is unset" '! out_has "logcat tag \[" && ! grep -Fq "logcat tag [" "$root"/release-logs/"$short"-*/launch-report.txt'
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

# This case mutates the config, so restore the real loader instead of the fixture's immutable cache.
unset -f jq qr_config_get
. "$QR_DIR/quest-release/config.sh"
jq '.quest.launchLogTags = ["Synthetic.Tag", "Synthetic\\Tag", "Synthetic:Part", "NotSeen", " Worker", "Worker"]' "$YETIKIT_CONFIG" > "$tmp/tag-config.json"
export YETIKIT_CONFIG="$tmp/tag-config.json"
reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
10-31 12:00:33.000  4242  4260 I Synthetic.Tag : synthetic line
W/Synthetic.Tag( 4242): another line
10-31 12:00:34.000  4242  4260 I SyntheticXTag : looks like a regex match
10-31 12:00:35.000  4242  4260 I Synthetic.TagExtra : prefixed tag
10-31 12:00:36.000  4242  4260 I Synthetic\Tag : backslash is literal
10-31 12:00:37.000  4242  4260 I Unity : Synthetic.Tag: not its tag
10-31 12:00:38.000  4242  4260 I Synthetic:Part: a colon within the tag
10-31 12:00:39.000  4242  4260 I  Worker : threadtime leading space with padding
10-31 12:00:40.000  4242  4260 I Worker  : threadtime without a leading space
W/ Worker ( 4242): brief leading space with padding" run launch
check "launch prints exact tag counts (including zero) without additional adb calls" \
  '[ "$rc" = 0 ] && [ "$(grep -c "logcat -d" "$tmp/adb.log")" = 1 ] && test "$(grep -F "logcat tag [" "$tmp/out")" = "$(printf "%s\n" "logcat tag [Synthetic.Tag]: 2" "logcat tag [Synthetic\Tag]: 1" "logcat tag [Synthetic:Part]: 1" "logcat tag [NotSeen]: 0" "logcat tag [ Worker]: 2" "logcat tag [Worker]: 1")"'
check "launch saves tag counts in the launch report" \
  'grep -Fq "logcat tag [Synthetic.Tag]: 2" "$root"/release-logs/"$short"-*/launch-report.txt'

qr_flow_finish
