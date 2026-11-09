#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_prepare

# --- gate ----------------------------------------------------------------------------------------------------------------------
check "the gate categories are MacOnly + Gfx (what the Linux pure pass excludes)" \
  '[ "$(qr_gate_categories "$repo")" = "Gfx;MacOnly" ] && [ "$(QUEST_GATE_CATEGORIES=MacOnly qr_gate_categories "$repo")" = MacOnly ]'
reset_logs; FAKE_XML="$xml_fail" run gate
check "a failed NUnit XML makes gate exit non-zero" '[ "$rc" != 0 ]'
check "gate runs EditMode with Metal graphics and -testCategory Gfx;MacOnly in the test worktree" \
  'grep -q -- "-force-metal -projectPath $root/rel-$short-test -runTests -testPlatform EditMode" "$tmp/unity.log" && grep -q -- "-testCategory Gfx;MacOnly" "$tmp/unity.log" && ! grep -q -- -nographics "$tmp/unity.log"'
check "gate prints the totals and each failure with its message (and a SetUp failure)" \
  'out_has "3 tests, 1 passed, 2 failed" && out_has "FAIL Synthetic.Props.Tests.PunchPlayModeTests.Haymaker: Expected knockdown but was <none>" && out_has "CourtPlayModeTests (SetUp): scene did not load"'
check "the summary lists the gate failures" 'grep -q "gate fails:  Synthetic.Props.Tests.PunchPlayModeTests.Haymaker" "$tmp/out"'
reset_logs; run gate
check "a passing XML: gate exits 0" '[ "$rc" = 0 ] && grep -q "gate:        Gfx;MacOnly: 3 tests, 3 passed, 0 failed" "$tmp/out"'
reset_logs; run gate --full
check "gate --full runs every test (no -testCategory)" '[ "$rc" = 0 ] && ! grep -q -- -testCategory "$tmp/unity.log"'
reset_logs; FAKE_UNITY_CRASH=1 run gate
check "a crash with no results XML fails the gate" '[ "$rc" != 0 ] && out_has "no results XML"'

# --- time box: force the portable watchdog even if coreutils is installed ----------------------------------------------------
# The shared fixture sources the timebox helper before defining fake adb.
check "the watchdog stops a run past its time box with 124" \
  'qr_test_watchdog_timeout'
check "a run inside its time box keeps its exit code" \
  '( qr_test_no_gtimeout; qr_timebox 5 sh -c "exit 3"; [ $? = 3 ] )'
check "the watchdog leaves no sleep behind (timed out or not)" \
  'qr_test_watchdog_cleanup'


qr_flow_finish
