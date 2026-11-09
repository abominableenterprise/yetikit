#!/usr/bin/env bash
# Synthetic editor regressions: evidence filtered-empty.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

FAKE_GFX_XML_MODE=zero run editmode
check "plain EditMode allows an implicit empty Gfx pass and explains why" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx: no tests selected (Gfx categories); treated as empty" "$tmp/err"'
FAKE_GFX_XML_MODE=zero run editmode -testFilter PureClass
check "filtered pure tests allow an empty Gfx pass with an explanation" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx: -testFilter.*PureClass.*no Gfx tests; pass empty" "$tmp/err"'
FAKE_XML_MODE=zero FAKE_GFX_XML_MODE=normal run editmode -testFilter GfxClass
check "filtered Gfx tests allow an empty pure pass with an explanation" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode: -testFilter.*GfxClass.*no pure tests; pass empty" "$tmp/err"'
FAKE_XML_MODE=zero run editmode -testFilter Nope
check "a filter matching neither pass fails closed and names the filter" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q -- "-testFilter.*Nope.*no executed tests across.*passes" "$tmp/err"'
FAKE_UNITY_RC=7 FAKE_GFX_XML_MODE=zero run editmode -testFilter PureClass
check "an empty filtered pass does not excuse an editor failure" '[ "$rc" = 7 ]'
FAKE_GFX_XML_MODE=zero run editmode -testCategory Gfx
check "an explicit Gfx category must execute tests" '[ "$rc" != 0 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
