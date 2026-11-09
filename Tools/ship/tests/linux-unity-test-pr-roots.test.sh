#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: configured consumer roots.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

pr_character_fixture
pr_builder_fixture

# --- nonstandard consumer roots (only runtime source changed) ----------------------------------------------------------
mkdir -p "$proj/Assets/_Project"
mv "$proj/Assets/Tests" "$proj/Assets/_Project/Tests"
mv "$proj/Assets/Scripts" "$proj/Assets/_Project/Scripts"
mv "$proj/Assets/Editor" "$proj/Assets/_Project/Editor"
t="$proj/Assets/_Project/Tests/EditMode"
mkdir -p "$t/Custom" "$proj/Assets/_Project/Scripts/Custom"
gfx "$t/Custom/XTests.cs" Example.Custom.Tests XTests Gfx
printf '// X\n' >> "$t/Custom/XTests.cs"
echo 'class X {}' > "$proj/Assets/_Project/Scripts/Custom/X.cs"
commit custom-layout
echo '// changed' >> "$proj/Assets/_Project/Scripts/Custom/X.cs"
pr HEAD
check "nonstandard layout without root keys selects no Gfx fixtures" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
jq '.tests += {root:"./Assets//_Project/Tests/", scriptsRoot:"./Assets/_Project/Scripts/", editorRoot:"Assets/_Project/Editor/"}' \
  "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
pr HEAD
check "configured roots select the Gfx fixture referencing changed runtime source" \
  '[ "$rc" = 0 ] && [ "$(filter)" = Example.Custom.Tests.XTests ]'
git -C "$proj" checkout -q -- Assets/_Project/Scripts/Custom/X.cs
printf '// changed test\n' >> "$t/Custom/XTests.cs"
pick
check "changed tests use the EditMode root derived from the canonical test root" \
  '[ "$(< "$tmp/picked")" = Example.Custom.Tests.XTests ]'
git -C "$proj" checkout -q -- Assets/_Project/Tests/EditMode/Custom/XTests.cs
echo '// changed builder' >> "$proj/Assets/_Project/Editor/World/Court/CourtBuilder.cs"
pick
check "configured editor root searches all configured tests for builder references" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Park.Tests.HoopTests ]'
git -C "$proj" checkout -q -- Assets/_Project/Editor/World/Court/CourtBuilder.cs
jq '.tests.builderFixtures["Assets/_Project/Editor/World/Walkers/BabySetup.cs"] = ["ExampleGame.Park.Tests.CourtTests"]' \
  "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
echo '// changed builder' >> "$proj/Assets/_Project/Editor/World/Walkers/BabySetup.cs"
pick
check "explicit builder dependencies resolve Gfx tags and fixture sources under tests.root" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Park.Tests.CourtTests ]'
git -C "$proj" checkout -q -- Assets/_Project/Editor/World/Walkers/BabySetup.cs

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
