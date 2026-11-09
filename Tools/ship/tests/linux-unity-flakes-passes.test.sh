#!/usr/bin/env bash
# Synthetic editor regressions: flakes passes.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

# --- the other passes -----------------------------------------------------------------------------------------------------
FAKE_FAILS="$ballers" run editmode
check "editmode: each pass retries its own flakes (editmode-retry.xml and editmode-gfx-retry.xml)" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 4 ] && [ -f "$OUT_DIR/editmode-retry.xml" ] && [ -f "$OUT_DIR/editmode-gfx-retry.xml" ] && [ "$(grep -c flaky-passed "$tmp/err")" = 2 ]'
FAKE_FAILS="$ballers" run playmode
check "playmode retries known flakes too" '[ "$rc" = 0 ] && [ -f "$OUT_DIR/playmode-retry.xml" ] && grep -q flaky-passed "$tmp/err"'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
