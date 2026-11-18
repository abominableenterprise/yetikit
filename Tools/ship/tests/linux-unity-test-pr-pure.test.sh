#!/usr/bin/env bash
# Synthetic editmode runs: opt-in selection, safe fallback and environment precedence.
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-test-pr-fixture.sh"
unset TEST_PR_PURE_ALL TEST_PR_PURE_MAX
stages="$OUT_DIR/test-stages.log"
full() { [ "$rc" = 0 ] && [[ "$(pure_run)" != *-testFilter* ]]; }

# A dirty runtime source selects the EditMode fixtures for its area.
echo '// runtime change' >> "$proj/Assets/Scripts/Props/Spray/Spray.cs"
pr
check 'without prPure, even a relevant change runs the full pure pass' 'full && [ "$(filter)" = ExampleGame.Props.Tests.SprayTests ]'

jq '.tests.prPure = {smokeFixtures:["ExampleGame.Pigeons.Tests.FlockTests"], max:8, fallbackRegex:"^ci/"}' \
  "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
commit opt-in
# Include dirty tracked and untracked changes relative to HEAD.
echo '// runtime change' >> "$proj/Assets/Scripts/Props/Spray/Spray.cs"
gfx "$t/Pigeons/NewTests.cs" ExampleGame.Pigeons.Tests NewTests PureUnityTest
pr HEAD
check 'pure uses the touched area, changed test and smoke fixture, while Gfx still picks by reference' \
  '[ "$rc" = 0 ] && [[ "$(pure_run)" == *"-testFilter ExampleGame.Pigeons.Tests.FlockTests;ExampleGame.Pigeons.Tests.NewTests;ExampleGame.Props.Tests.RulesTests"* ]] && [ "$(filter)" = ExampleGame.Props.Tests.SprayTests ]'
check 'stage log records reasons for all three kinds of selection' \
  'grep -Fq "configured smoke fixture" "$stages" && grep -Fq "Assets/Scripts/Props/Spray/Spray.cs" "$stages" && grep -Fq "Assets/Tests/EditMode/Pigeons/NewTests.cs" "$stages"'

TEST_PR_PURE_ALL=1 TEST_PR_PURE_MAX=1 pr HEAD
check 'ALL overrides selection even with MAX set' 'full && grep -Fq "TEST_PR_PURE_ALL=1" "$stages"'
TEST_PR_PURE_MAX=2 pr HEAD
check 'MAX lowers the cap; overflow falls back instead of dropping fixtures' 'full && grep -Fq "exceed max 2" "$stages"'
TEST_PR_PURE_MAX=0003 pr HEAD
check 'MAX accepts decimal with leading zeroes and includes the entire selection at the cap' \
  '[ "$rc" = 0 ] && [[ "$(pure_run)" == *"-testFilter ExampleGame.Pigeons.Tests.FlockTests;ExampleGame.Pigeons.Tests.NewTests;ExampleGame.Props.Tests.RulesTests"* ]]'
TEST_PR_PURE_MAX=bad pr HEAD
check 'invalid MAX falls back safely' 'full && grep -Fq "invalid TEST_PR_PURE_MAX" "$stages"'

commit initial-selection
printf 'using NUnit.Framework;\nnamespace ShipFixtures\n{\n [Explicit, Category ( "RenderTool" )]\n public class CaptureTests { [Test] public void Capture() {} }\n}\n' > "$t/Props/CaptureTests.cs"
pr HEAD
check 'spaced RenderTool category keeps an explicit fixture out of the headless filter' \
  '[ "$rc" = 0 ] && [[ "$(pure_run)" == *"-testFilter ExampleGame.Pigeons.Tests.FlockTests "* ]] && ! grep -Fq "pure selected ShipFixtures.CaptureTests" "$stages"'
rm "$t/Props/CaptureTests.cs"

printf 'using NUnit.Framework;\nnamespace ShipFixtures { public class InlineTests {\n [Test] public void Rule() {}\n} }\n' > "$t/Props/InlineTests.cs"
pr HEAD
check 'a same-line namespace and class is selected alongside smoke' \
  '[ "$rc" = 0 ] && [[ "$(pure_run)" == *"-testFilter ExampleGame.Pigeons.Tests.FlockTests;ShipFixtures.InlineTests "* ]]'
rm "$t/Props/InlineTests.cs"

printf '// This changed source declares no class.\n' > "$t/Props/Unresolved.cs"
echo '// another runtime change' >> "$proj/Assets/Scripts/Props/Spray/Spray.cs"
pr HEAD
check 'an unresolved changed test source forces full pure even with smoke and an earlier area match' \
  'full && grep -Fq "no classes found in changed test Assets/Tests/EditMode/Props/Unresolved.cs" "$stages" && ! grep -Fq "pure selected" "$stages"'
rm "$t/Props/Unresolved.cs"

# Run from a vendored layout. Moving the tool directory must not hard-code its old prefix.
mv "$proj/Tools/ship" "$proj/Tools/yetikit"
script="$proj/Tools/yetikit/linux-unity.sh"
commit vendored
printf 'version update\n' > "$proj/Tools/yetikit/VERSION"
pr HEAD
check 'untracked vendored tool change forces full pure even with custom fallbackRegex' \
  'full && grep -Fq "Tools/yetikit/VERSION" "$stages"'
rm "$proj/Tools/yetikit/VERSION"
mkdir -p "$proj/ci"
echo infra > "$proj/ci/check.sh"
pr HEAD
check 'custom infrastructure regex also forces full pure' 'full && grep -Fq "ci/check.sh" "$stages"'
git -C "$proj" add ci/check.sh; commit infra
mkdir -p "$proj/renamed"
git -C "$proj" mv ci/check.sh renamed/check.sh
pr HEAD
check 'renaming infrastructure out of its old path still forces full pure' \
  'full && grep -Fq "ci/check.sh" "$stages"'
commit rename-infra
mkdir -p "$proj/ProjectSettings"
echo setting > "$proj/ProjectSettings/ProjectVersion.txt"
pr HEAD
check 'project settings force full pure' 'full && grep -Fq "ProjectSettings/ProjectVersion.txt" "$stages"'
rm "$proj/ProjectSettings/ProjectVersion.txt"
pr HEAD
check 'unchanged opt-in branch runs the configured smoke fixture' \
  '[ "$rc" = 0 ] && [[ "$(pure_run)" == *"-testFilter ExampleGame.Pigeons.Tests.FlockTests "* ]]'
FAKE_XML_MODE=zero pr HEAD
check 'filtered pure pass still requires executed tests' '[ "$rc" != 0 ] && grep -Fq "no executed tests" "$tmp/err"'

jq '.tests.prPure = {}' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
commit empty-opt-in
pr HEAD
check 'without matching tests or smoke fixtures run full pure, not an empty pass' \
  'full && grep -Fq "no pure fixtures selected" "$stages"'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
