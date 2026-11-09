#!/usr/bin/env bash
# Synthetic editor regressions: flakes retry-coverage.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

for missing in "$flick2" "$ballers"; do
  if [ "$missing" = "$ballers" ]; then passes="$flick1;$flick2"; else passes="$ballers;$flick1"; fi
  FAKE_FAILS="$ballers;$flick1;$flick2" FAKE_RETRY_PASSES="$passes" FAKE_RETRY_SKIPS="$missing" EDITMODE_GFX=0 run editmode
  check "a retry with a skipped original failure ($missing) stays failed" \
    '[ "$rc" = 2 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && ! grep -q flaky-passed "$tmp/err"'
done
FAKE_FAILS="$ballers;$flick1;$flick2" FAKE_RETRY_PASSES="$ballers;$flick1" EDITMODE_GFX=0 run editmode
check "a retry missing one original parameterized case stays failed" \
  '[ "$rc" = 2 ] && ! grep -q flaky-passed "$tmp/err"'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
