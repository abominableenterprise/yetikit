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
for mode in fail empty ambiguous; do
  reset_logs; FAKE_ACTIVITY_MODE="$mode" run install "$apk" --force
  check "install --force refuses $mode ACTIVITY dumpsys without backup or install" \
    '[ "$rc" != 0 ] && out_has "cannot determine" && [ ! -f "$tmp/installed" ] && ! grep -q "exec-out" "$tmp/adb.log"'
done
for mode in fail empty ambiguous conflicting; do
  reset_logs; FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_POWER_MODE="$mode" run install "$apk" --force
  check "install --force refuses $mode POWER dumpsys (no headset state) without backup or install" \
    '[ "$rc" != 0 ] && out_has "cannot determine" && [ ! -f "$tmp/installed" ] && ! grep -q "exec-out" "$tmp/adb.log"'
done
reset_logs; FAKE_HMT=0 FAKE_HMT_RC=1 FAKE_FIXTURE=game-mounted run install "$apk"
check "failed mounted query printing zero cannot override a worn headset" \
  '[ "$rc" != 0 ] && out_has "headset in use" && [ ! -f "$tmp/installed" ]'
reset_logs; FAKE_HMT=0 FAKE_HMT_RC=1 FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_POWER_MODE=empty run install "$apk" --force
check "failed mounted query with unknown power fails safe even with --force" \
  '[ "$rc" != 0 ] && out_has "cannot determine" && [ ! -f "$tmp/installed" ]'

qr_flow_finish
