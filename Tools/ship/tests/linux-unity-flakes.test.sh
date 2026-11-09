#!/usr/bin/env bash
# Synthetic editor regressions: flakes core.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

# --- only known flakes failed, and they pass on the rerun ----------------------------------------------------------------
FAKE_FAILS="$ballers;$flick1;$flick2" EDITMODE_GFX=0 run editmode
check "only known flakes failed, green rerun: exit 0" '[ "$rc" = 0 ]'
check "it prints flaky-passed with the names" \
  'grep -qF "[linux-unity] flaky-passed: $ballers $flick1 $flick2" "$tmp/err"'
check "the rerun is one more editor run, the same pass, with a -testFilter of just the flakes (cases as their method)" \
  '[ "$(wc -l < "$tmp/runs")" = 2 ] && [ "$(retry_filter)" = "$ballers;X.Tests.Throw.AFlick" ] && grep -- -retry.xml "$tmp/runs" | grep -q -- "-nographics.*-testCategory !Gfx;!MacOnly"'
check "both runs' results are kept: editmode.xml (failed) and editmode-retry.xml (passed)" \
  'grep -q "failed=\"3\"" "$OUT_DIR/editmode.xml" && grep -q "failed=\"0\"" "$OUT_DIR/editmode-retry.xml" && [ -f "$OUT_DIR/editmode-retry.log" ]'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
