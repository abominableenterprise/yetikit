#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: dirty, untracked and assembly-fallback runtime references.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"


echo '// wip' >> "$proj/Assets/Scripts/Park/Court.cs"
pr HEAD
check "uncommitted runtime changes include a partial fixture tagged in another file" \
  '[ "$(filter)" = "ExampleGame.Park.Tests.CourtTests;ExampleGame.Park.Tests.PetTests" ]'
check "runtime references do not escape the area folder into world tests" '! filter | grep -qE "HoopTests|SplatTests"'
git -C "$proj" checkout -q -- Assets/Scripts/Park/Court.cs
echo 'class Coo {}' > "$proj/Assets/Scripts/Pigeons/Coo.cs"
pr HEAD
check "untracked runtime class: method-level Gfx tag and file-scoped namespace count" \
  '[ "$(filter)" = ExampleGame.Pigeons.Tests.PerchTests ]'
rm "$proj/Assets/Scripts/Pigeons/Coo.cs"
echo 'class Unreferenced {}' > "$proj/Assets/Scripts/Props/Unreferenced.cs"
pr HEAD
check "runtime class with no references selects nothing, not the whole area" '[ "$(wc -l < "$tmp/runs")" = 1 ]'
rm "$proj/Assets/Scripts/Props/Unreferenced.cs"
# Assembly-name fallback for areas whose tests live directly at the EditMode root.
echo '{}' > "$t/ExampleGame.Characters.Tests.asmdef"
gfx "$t/PersonTests.cs" ExampleGame.Characters.Tests PersonTests Gfx
printf '// Person\n' >> "$t/PersonTests.cs"
mkdir -p "$proj/Assets/Scripts/Characters"
echo 'class Person {}' > "$proj/Assets/Scripts/Characters/Person.cs"
commit character-fixtures
echo '// tweak' >> "$proj/Assets/Scripts/Characters/Person.cs"
pr HEAD
check "runtime lookup retains the asmdef-folder fallback" '[ "$(filter)" = ExampleGame.Characters.Tests.PersonTests ]'
git -C "$proj" checkout -q -- Assets/Scripts/Characters/Person.cs


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
