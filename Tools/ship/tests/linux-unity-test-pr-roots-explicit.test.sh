#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: independent EditMode roots and discovery helpers.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

pr_configured_roots_fixture

# An independent EditMode root and asmdef fallback work without prefix assumptions.
mv "$t" "$proj/Assets/_Project/Edit Tests"
jq '.tests.editModeRoot = "./Assets//_Project/Edit Tests/"' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
# Gfx eligibility still comes from tests.root, so include the independent folder there.
jq '.tests.root = "Assets/_Project"' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
commit explicit-editmode-layout
echo '// changed' >> "$proj/Assets/_Project/Scripts/Characters/Person.cs"
pick
check "explicit EditMode root supports spaces and the asmdef fallback" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Characters.Tests.PersonTests ]'
(
  cd "$proj"; . "$script"
  printf '%s\n' Assets/_Project/Scripts/Custom/X.cs | pr_test_files > "$tmp/test-files"
  printf 'Court\n' | pr_area_tests > "$tmp/area-tests"
  gfx_file="$PROJECT/Assets/_Project/ToolCapture.cs"
  printf 'namespace Example.Tools\n{\n [Category("RenderTool")]\n public class Capture {}\n}\n' > "$gfx_file"
  render_tool_classes > "$tmp/render-tools"
)
check "pr_test_files uses the configured scripts and EditMode roots" \
  'grep -Fxq "Assets/_Project/Edit Tests/Custom/XTests.cs" "$tmp/test-files"'
check "area tags are discovered under the configured test root" \
  'grep -Fxq ExampleGame.Park.Tests.HoopTests "$tmp/area-tests"'
check "RenderTool discovery uses the configured test root" \
  'grep -Fxq Capture "$tmp/render-tools"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
