#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build

# --- install ---------------------------------------------------------------------------------------------------------------------
reset_logs; FAKE_MAKER=samsung run install "$apk"
check "install refuses a non-Oculus device and installs nothing" '[ "$rc" != 0 ] && out_has "not Oculus" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_FIXTURE=game-mounted run install "$apk"
check "install refuses when the game is focused and the headset is worn" '[ "$rc" != 0 ] && out_has "headset in use" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_FIXTURE=other-app-mounted run install "$apk"
check "install refuses when another app is focused and the headset is worn" '[ "$rc" != 0 ] && out_has "com.oculus.browser" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_FIXTURE=game-unmounted run install "$apk"
check "the game focused on an unmounted headset counts as idle" '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (not worn (HEADSET_UNMOUNTED)" "$tmp/out"'
reset_logs; FAKE_FIXTURE=game-standby-history run install "$apk"
check "State: STANDBY with an old HEADSET_MOUNTED transition line counts as idle" \
  '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (not worn (STANDBY)" "$tmp/out"'
reset_logs; FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_HMT=0 run install "$apk"
check "no vrpowermanager, display on, getprop sys.hmt.mounted 0: idle" \
  '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (not worn (sys.hmt.mounted=0)" "$tmp/out" && grep -q "shell getprop sys.hmt.mounted" "$tmp/adb.log"'
reset_logs; FAKE_FIXTURE=game-mounted run install "$apk" --force
check "--force installs over a headset in use" '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && grep -q "idle check:  IN USE.*--force" "$tmp/out"'
reset_logs; run install "$apk"
check "Quest's several topResumedActivity lines with Home focused: idle" \
  '[ "$rc" = 0 ] && [ -f "$tmp/installed" ] && grep -q "idle check:  idle (Home focused)" "$tmp/out"'

qr_flow_finish
