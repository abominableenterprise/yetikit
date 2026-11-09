#!/usr/bin/env bash
# Synthetic editor regressions: evidence core.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

for platform in editmode playmode; do
  FAKE_XML_MODE=no-file EDITMODE_GFX=0 run "$platform"
  check "$platform: exit 0 without XML fails, naming the pass and missing XML" \
    '[ "$rc" != 0 ] && grep -q "$platform:.*missing.*XML" "$tmp/err"'
done
for mode in empty garbage zero skipped; do
  FAKE_XML_MODE="$mode" EDITMODE_GFX=0 run editmode
  check "pure pass: $mode evidence fails with a reason" \
    '[ "$rc" != 0 ] && grep -q "editmode:.*test evidence" "$tmp/err"'
done
for platform in editmode playmode pr; do
  for arg in -quit -testResults -logFile; do
    extra=("$arg"); [ "$arg" = -quit ] || extra+=(x)
    run "$platform" "${extra[@]}"
    check "$platform: $arg rejected before any editor starts" \
      '[ "$rc" != 0 ] && [ ! -s "$tmp/runs" ] && grep -q -- "error:.*$arg.*not allowed" "$tmp/err"'
  done
done

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
