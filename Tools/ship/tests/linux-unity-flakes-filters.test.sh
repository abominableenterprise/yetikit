#!/usr/bin/env bash
# Synthetic editor regressions: flakes filters.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

FAKE_FAILS=X.Tests.Seam.Padding EDITMODE_GFX=0 run editmode
check "a test of a listed fixture counts as a known flake" '[ "$rc" = 0 ] && grep -q "flaky-passed: X.Tests.Seam.Padding" "$tmp/err"'

FAKE_FAILS="$ballers" EDITMODE_GFX=0 run editmode -testFilter X.Tests -logLevel x
check "the rerun replaces the caller's -testFilter and keeps its other args" \
  '[ "$rc" = 0 ] && [ "$(retry_filter)" = "$ballers" ] && [ "$(grep -- -retry.xml "$tmp/runs" | grep -o -- -testFilter | wc -l)" = 1 ] && grep -- -retry.xml "$tmp/runs" | grep -q -- "-logLevel x"'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
