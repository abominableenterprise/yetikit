#!/usr/bin/env bash
# Shared synthetic PR-selection fixture; each topical test owns its temp repository.
# Setup helpers reproduce prerequisite state without replaying earlier editor runs.
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"

# The fake editor exits synchronously and leaves no editor workers to settle.
# Remove only cleanup's fixed grace sleep in the temporary vendored copy;
# process inspection, shared-file safety checks and real timeouts stay intact.
python3 - "$script" "$proj" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
assert path.resolve().is_relative_to(Path(sys.argv[2]).resolve())
source = path.read_text()
needle = '  sleep 2\n  wipe_unity_shared_files\n'
assert source.count(needle) == 1
path.write_text(source.replace(needle, '  wipe_unity_shared_files\n'))
PY
unset TEST_PR_GFX_MAX

t="$proj/Assets/Tests/EditMode"
mkdir -p "$proj/Assets/Scripts/Props/Spray" "$proj/Assets/Scripts/Park" "$proj/Assets/Scripts/Pigeons" "$t/Props" "$t/Park" "$t/Pigeons"
gfx() { # $1 file, $2 namespace, $3 class, $4 category
  printf 'using NUnit.Framework;\n\nnamespace %s\n{\n    /// <summary>A [Category("Gfx")] mention in a comment.</summary>\n    [Category("%s")]\n    public class %s\n    {\n        sealed class Inner { }\n        [Test] public void A() { }\n    }\n}\n' "$2" "$4" "$3" > "$1"
}
gfx "$t/Props/SprayTests.cs" ExampleGame.Props.Tests SprayTests Gfx
gfx "$t/Props/ThrowTests.cs" ExampleGame.Props.Tests ThrowTests Gfx
gfx "$t/Props/RulesTests.cs" ExampleGame.Props.Tests RulesTests PureUnityTest
gfx "$t/Park/CourtTests.cs" ExampleGame.Park.Tests CourtTests Gfx
gfx "$t/Pigeons/FlockTests.cs" ExampleGame.Pigeons.Tests FlockTests PureUnityTest
printf '// Spray\n' >> "$t/Props/SprayTests.cs"
printf '// Spray\n' >> "$t/Props/RulesTests.cs"
printf '// SprayBottle\n' >> "$t/Props/ThrowTests.cs"
printf '// Court\n' >> "$t/Park/CourtTests.cs"
# A file-scoped namespace and a class whose only Gfx tag is on a method.
printf 'namespace ExampleGame.Pigeons.Tests;\n\npublic class PerchTests\n{\n    [UnityTest]\n    [Category("Gfx")]\n    public IEnumerator Lands() { yield break; }\n}\n// Coo\n' > "$t/Pigeons/PerchTests.cs"
# A partial class tagged in its other file; the referencing source is untagged.
printf 'namespace ExampleGame.Park.Tests\n{\n    public partial class PetTests\n    {\n    }\n}\n// Court\n' > "$t/Park/PetMore.cs"
printf 'namespace ExampleGame.Park.Tests\n{\n    [Category("Gfx")]\n    public partial class PetTests { }\n}\n' > "$t/Park/PetTests.cs"
echo 'class Spray {}' > "$proj/Assets/Scripts/Props/Spray/Spray.cs"
echo 'class Court {}' > "$proj/Assets/Scripts/Park/Court.cs"
echo 'class Flock {}' > "$proj/Assets/Scripts/Pigeons/Flock.cs"
echo docs > "$proj/README.md"
# Area tags and the builder table must not broaden the Gfx picker, even when multiple areas share a builder.
mkdir -p "$proj/Assets/Art/World/Areas" "$proj/Assets/Editor/World/Court" "$proj/Tools/ship" "$t/World"
echo prefab > "$proj/Assets/Art/World/Areas/Court.prefab"
echo 'class CourtBuilder {}' > "$proj/Assets/Editor/World/Court/CourtBuilder.cs"
echo 'class WorldSauce {}' > "$proj/Assets/Editor/World/WorldSauce.cs"
printf 'Court Assets/Editor/World/Court/*\nSauceFx Assets/Editor/World/WorldSauce.cs\nOther Assets/Editor/World/Court/*\n' > "$proj/Tools/ship/world-areas.txt"
printf 'namespace ExampleGame.Park.Tests\n{\n    [Category("Gfx")]\n    [Category("Area:Court")]\n    public class HoopTests { }\n}\n// CourtBuilder and Court\n' > "$t/World/HoopTests.cs"
printf 'namespace ExampleGame.World.Tests\n{\n    [Category("Area:Court")]\n    public class SlabTests { }\n}\n// CourtBuilder\n' > "$t/World/SlabTests.cs"
printf 'namespace ExampleGame.World.Tests\n{\n    [Category("Gfx")]\n    [Category("Area:SauceFx")]\n    [Category("Area:Court")]\n    public class SplatTests { }\n}\n' > "$t/World/SplatTests.cs"
git_init

pr() { : > "$tmp/runs"; rc=0; bash "$script" test pr "$@" 2>"$tmp/err" || rc=$?; }
pure_run() { sed -n 1p "$tmp/runs"; }
gfx_run() { sed -n 2p "$tmp/runs"; }
filter() { gfx_run | sed -n 's/.*-testFilter \([^ ]*\).*/\1/p'; }

pick() { (cd "$proj"; . "$script"; pr_gfx_fixtures HEAD) > "$tmp/picked" 2> "$tmp/pick-err"; }

pr_changed_test_fixture() {
  git -C "$proj" checkout -q -b feature
  echo more >> "$proj/README.md"; commit docs
  echo '// tweak' >> "$t/Props/ThrowTests.cs"; commit throw
}

pr_character_fixture() {
  echo '{}' > "$t/ExampleGame.Characters.Tests.asmdef"
  gfx "$t/PersonTests.cs" ExampleGame.Characters.Tests PersonTests Gfx
  printf '// Person\n' >> "$t/PersonTests.cs"
  mkdir -p "$proj/Assets/Scripts/Characters"
  echo 'class Person {}' > "$proj/Assets/Scripts/Characters/Person.cs"
  commit character-fixtures
}

pr_builder_fixture() {
  mkdir -p "$proj/Assets/Editor/World/Walkers"
  echo 'class BabySetup {}' > "$proj/Assets/Editor/World/Walkers/BabySetup.cs"
  jq '.tests.builderFixtures["Assets/Editor/World/Walkers/BabySetup.cs"] = ["ExampleGame.Park.Tests.CourtTests"]' "$proj/yetikit.json" > "$tmp/config.json"
  mv "$tmp/config.json" "$proj/yetikit.json"
  printf '// explicit dependency; no builder identifier reference\n' >> "$t/Park/CourtTests.cs"
  commit baby-reference
}

pr_custom_layout_fixture() {
  pr_character_fixture
  pr_builder_fixture
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
}

pr_configured_roots_fixture() {
  pr_custom_layout_fixture
  jq '.tests += {root:"./Assets//_Project/Tests/", scriptsRoot:"./Assets/_Project/Scripts/", editorRoot:"Assets/_Project/Editor/"}' \
    "$proj/yetikit.json" > "$tmp/config.json"
  mv "$tmp/config.json" "$proj/yetikit.json"
  jq '.tests.builderFixtures["Assets/_Project/Editor/World/Walkers/BabySetup.cs"] = ["ExampleGame.Park.Tests.CourtTests"]' \
    "$proj/yetikit.json" > "$tmp/config.json"
  mv "$tmp/config.json" "$proj/yetikit.json"
}

pr_explicit_roots_fixture() {
  pr_configured_roots_fixture
  # An independent EditMode root and asmdef fallback work without prefix assumptions.
  mv "$t" "$proj/Assets/_Project/Edit Tests"
  jq '.tests.editModeRoot = "./Assets//_Project/Edit Tests/"' "$proj/yetikit.json" > "$tmp/config.json"
  mv "$tmp/config.json" "$proj/yetikit.json"
  # Gfx eligibility still comes from tests.root, so include the independent folder there.
  jq '.tests.root = "Assets/_Project"' "$proj/yetikit.json" > "$tmp/config.json"
  mv "$tmp/config.json" "$proj/yetikit.json"
  commit explicit-editmode-layout
}
