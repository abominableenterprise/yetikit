#!/usr/bin/env bash
# Synthetic editor regressions: evidence pr.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

# A changed Gfx fixture makes test pr actually invoke its optional Gfx pass.
mkdir -p "$proj/Assets/Tests/EditMode"
fixture="$proj/Assets/Tests/EditMode/GraphicsTests.cs"
printf 'namespace X.Tests {\n[Category("Gfx")]\npublic class GraphicsTests { }\n}\n' > "$fixture"
git_init
printf '// changed\n' >> "$fixture"
FAKE_GFX_XML_MODE=zero run pr
check "PR Gfx may select zero tests with the same explanation" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx: no tests selected (Gfx categories); treated as empty" "$tmp/err"'
FAKE_XML_MODE=zero EDITMODE_GFX=0 run pr
check "PR pure pass may not select zero tests" '[ "$rc" != 0 ]'

for platform in editmode pr; do
  FAKE_FAILS=X.Tests.Broken FAKE_GFX_XML_MODE=no-file run "$platform"
  check "$platform: a later evidence-only failure preserves editor exit 2" \
    '[ "$rc" = 2 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx:.*missing.*XML" "$tmp/err"'
done


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
