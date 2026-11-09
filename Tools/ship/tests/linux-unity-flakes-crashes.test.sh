#!/usr/bin/env bash
# Synthetic editor regressions: flakes crashes.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

FAKE_NO_XML=1 EDITMODE_GFX=0 run editmode
check "a crash with no results XML is never a flake" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
FAKE_FAILS="$ballers" run playmode; FAKE_NO_XML=1 run playmode
check "a crash after an earlier flaky run never reruns the stale XML's flakes" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ ! -f "$OUT_DIR/playmode.xml" ] && ! grep -q flaky-passed "$tmp/err"'
KNOWN_FLAKES="$tmp/none.txt" FAKE_FAILS="$ballers" EDITMODE_GFX=0 run editmode
check "no known-flakes file: every failure is real" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
