#!/usr/bin/env bash
# Synthetic editor regressions: flakes real-failures.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

# --- real failures still fail --------------------------------------------------------------------------------------------
FAKE_FAILS="$ballers;X.Tests.Real.Broken" EDITMODE_GFX=0 run editmode
check "a failure not in the list: exit nonzero, no rerun" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q "X.Tests.Real.Broken failed and is not a known flake" "$tmp/err" && ! grep -q flaky-passed "$tmp/err"'
FAKE_FAILS=X.Tests.Court.TheBallersKeepPlayingToo EDITMODE_GFX=0 run editmode
check "a longer name sharing a listed prefix is not a known flake" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
FAKE_FAILS="$ballers" FAKE_RETRY_FAILS="$ballers" EDITMODE_GFX=0 run editmode
check "a known flake that fails again: exit nonzero, both XMLs written" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "failed again" "$tmp/err" && grep -q "failed=\"1\"" "$OUT_DIR/editmode-retry.xml" && ! grep -q flaky-passed "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
