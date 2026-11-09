#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Real timeouts kill gated editors; external SIGKILL stays distinct.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-timeout-fixture.sh"
run FAKE_EDITOR_GATE="$tmp/timeout-editor" UNITY_GFX_TIMEOUT=1 bash "$script" test editmode -testCategory Gfx
check "a Gfx editor blocked at its gate past a 1 s timeout is killed: the run fails" '[ "$rc" != 0 ]'
check "it prints the killed line naming UNITY_GFX_TIMEOUT" \
  'grep -qF "[linux-unity] editmode: killed at the 1 s timeout; no results. Re-run with UNITY_GFX_TIMEOUT=2" "$tmp/err"'
check "and no results" 'grep -q "no results in .*editmode.xml" "$tmp/err"'
run FAKE_EDITOR_GATE="$tmp/timeout-editor" UNITY_TIMEOUT=1 EDITMODE_GFX=0 bash "$script" test editmode
check "a killed pure pass names UNITY_TIMEOUT" \
  '[ "$rc" != 0 ] && grep -qF "editmode: killed at the 1 s timeout; no results. Re-run with UNITY_TIMEOUT=2" "$tmp/err"'
run FAKE_UNITY_RC=137 bash "$script" open
check "a SIGKILL before the timeout is not reported as the timeout" \
  '[ "$rc" != 0 ] && grep -q "editor: killed (SIGKILL) after [0-9.]* s, before the 1800 s timeout" "$tmp/err" && ! grep -q "killed at the" "$tmp/err"'
run bash "$script" test editmode
check "a normal run prints no killed line" '[ "$rc" = 0 ] && ! grep -q killed "$tmp/err"'
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
