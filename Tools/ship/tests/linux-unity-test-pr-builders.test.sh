#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: scene builder references and explicit dependencies.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"


# --- scene builders: references only, never area expansion -------------------------------------------------------------
echo more >> "$proj/Assets/Art/World/Areas/Court.prefab"
pr HEAD
check "changed scene-area prefab does not select all tagged Gfx fixtures" '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
git -C "$proj" checkout -q -- Assets/Art/World/Areas/Court.prefab
echo '// tweak' >> "$proj/Assets/Editor/World/Court/CourtBuilder.cs"
pr HEAD
check "scene builder selects only referencing Gfx fixtures, not all its areas" \
  '[ "$rc" = 0 ] && [ "$(filter)" = ExampleGame.Park.Tests.HoopTests ]'
check "builder selection explains its reference, excludes pure and area-only tests" \
  'grep -q "why: references builder CourtBuilder" "$tmp/err" && ! filter | grep -qE "SlabTests|SplatTests"'
git -C "$proj" checkout -q -- Assets/Editor/World/Court/CourtBuilder.cs
echo '// tweak' >> "$proj/Assets/Editor/World/WorldSauce.cs"
pr HEAD
check "scene builder with no references selects nothing despite its area table entry" '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
git -C "$proj" checkout -q -- Assets/Editor/World/WorldSauce.cs
# References, not the legacy explicit dependency map, also govern the previously special-cased builders.
mkdir -p "$proj/Assets/Editor/World/Walkers"
echo 'class BabySetup {}' > "$proj/Assets/Editor/World/Walkers/BabySetup.cs"
jq '.tests.builderFixtures["Assets/Editor/World/Walkers/BabySetup.cs"] = ["ExampleGame.Park.Tests.CourtTests"]' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
pr HEAD
check "a configured builder selects its Gfx fixture without source references" '[ "$(wc -l < "$tmp/runs")" = 2 ] && [ "$(filter)" = ExampleGame.Park.Tests.CourtTests ]'
printf '// explicit dependency; no builder identifier reference\n' >> "$t/Park/CourtTests.cs"
commit baby-reference
echo '// tweak' >> "$proj/Assets/Editor/World/Walkers/BabySetup.cs"
SCENE_AREAS=/nonexistent pr HEAD
check "a legacy mapped builder selects actual references even without an area table" \
  '[ "$(filter)" = ExampleGame.Park.Tests.CourtTests ]'
git -C "$proj" checkout -q -- Assets/Editor/World/Walkers/BabySetup.cs
# Deleted builders still match by their class name; the source file need not survive.
rm "$proj/Assets/Editor/World/Court/CourtBuilder.cs"
pr HEAD
check "a deleted builder selects its referencing fixture" '[ "$(filter)" = ExampleGame.Park.Tests.HoopTests ]'
git -C "$proj" checkout -q -- Assets/Editor/World/Court/CourtBuilder.cs


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
