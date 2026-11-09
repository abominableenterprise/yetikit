#!/usr/bin/env bash
# Synthetic editor regressions: evidence retry.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

for mode in no-file empty garbage zero skipped; do
  FAKE_FAILS=X.Tests.Flaky KNOWN_FLAKES="$tmp/flakes" FAKE_RETRY_XML_MODE="$mode" EDITMODE_GFX=0 run editmode
  check "retry with $mode evidence cannot turn the original failure green" \
    '[ "$rc" = 2 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && ! grep -q flaky-passed "$tmp/err" && grep -q "editmode-retry:.*test evidence" "$tmp/err"'
done
FAKE_FAILS=X.Tests.Flaky KNOWN_FLAKES="$tmp/flakes" FAKE_RETRY_XML_MODE=zero run editmode -testFilter PureClass
check "filtered dual-pass retries must still execute tests" \
  '[ "$rc" = 2 ] && grep -q "editmode-retry:.*test evidence" "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
