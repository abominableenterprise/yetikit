#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build

# Unknown or failed headset-state probes must fail closed even with --force.
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
