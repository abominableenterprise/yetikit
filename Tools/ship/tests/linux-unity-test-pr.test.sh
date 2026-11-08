#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Tests `linux-unity.sh test pr [base]`: full pure pass, then only changed/referencing Gfx classes, with a bounded
# recent-first fallback. Fake editor and fixture files live exclusively in a temp git repo; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-test-pr.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "$0")/lib/fake-unity.sh"
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

# --- nothing touched and changed test classes -------------------------------------------------------------------------
git -C "$proj" checkout -q -b feature
echo more >> "$proj/README.md"; commit docs
pr
check "no Gfx fixture touched: only the pure pass runs" '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
check "the pure pass is full (-nographics, !Gfx;!MacOnly, no -testFilter)" \
  'pure_run | grep -q -- "-nographics -runTests -testPlatform EditMode -testCategory !Gfx;!MacOnly" && ! pure_run | grep -q -- -testFilter'
check "it logs no Gfx fixtures touched" 'grep -q "no Gfx fixtures touched" "$tmp/err"'
check "pure results are in editmode.xml" 'grep -q "<test-run" "$OUT_DIR/editmode.xml" && [ ! -f "$OUT_DIR/editmode-gfx.xml" ]'
echo '// tweak' >> "$t/Props/ThrowTests.cs"; commit throw
pr
check "a changed Gfx test file gets a second pass, with only its declared fixture" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && [ "$(filter)" = ExampleGame.Props.Tests.ThrowTests ]'
check "the Gfx pass uses Xvfb and the Gfx category" '! gfx_run | grep -q -- -nographics && gfx_run | grep -q -- "-testCategory Gfx"'
check "stderr explains the changed-test selection" \
  'grep -q "selected ExampleGame.Props.Tests.ThrowTests" "$tmp/err" && grep -q "why: changed test Assets/Tests/EditMode/Props/ThrowTests.cs" "$tmp/err"'
check "Gfx results are in editmode-gfx.xml" 'grep -q ThrowTests "$OUT_DIR/editmode-gfx.xml"'
# Multiple declarations in one changed source; a non-Gfx class is excluded.
printf '\nnamespace ExampleGame.Props.Tests\n{\n    [Category("Gfx")]\n    public class ExtraTests { }\n    public class PureExtraTests { }\n}\n' >> "$t/Props/ThrowTests.cs"
pr HEAD
check "a changed test file selects every Gfx class declared there, not the whole folder" \
  '[ "$(filter)" = "ExampleGame.Props.Tests.ExtraTests;ExampleGame.Props.Tests.ThrowTests" ]'
git -C "$proj" checkout -q -- Assets/Tests/EditMode/Props/ThrowTests.cs

# --- runtime changes: whole-word references in the matching area only -------------------------------------------------
echo '// tweak' >> "$proj/Assets/Scripts/Props/Spray/Spray.cs"
pr HEAD
check "a runtime class selects only the one Gfx fixture whose source mentions that class" \
  '[ "$rc" = 0 ] && [ "$(filter)" = ExampleGame.Props.Tests.SprayTests ]'
check "runtime selection logs the reference and source" \
  'grep -q "why: references Spray from Assets/Scripts/Props/Spray/Spray.cs" "$tmp/err"'
check "pure fixtures, nested classes and substring-only references are excluded" '! filter | grep -qE "RulesTests|Inner|ThrowTests"'
commit spray
pr
check "changed tests and referencing runtime fixtures are unioned and sorted" \
  '[ "$(filter)" = "ExampleGame.Props.Tests.SprayTests;ExampleGame.Props.Tests.ThrowTests" ]'
pr HEAD
check "test pr HEAD: nothing changed, Gfx pass skipped" '[ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q "no Gfx fixtures touched" "$tmp/err"'
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

# --- bounded selection, deterministic newest-first fallback ------------------------------------------------------------
# Call the helper directly to assert stdout is ONLY fixture names and stderr contains the explanation. Controlled
# timestamps avoid sleeps; committed sources use commit time, dirty/untracked sources use mtime and rank first.
pick() { (cd "$proj"; . "$script"; pr_gfx_fixtures HEAD) > "$tmp/picked" 2> "$tmp/pick-err"; }
mkdir -p "$t/Cap" "$proj/Assets/Scripts/Cap"
echo 'class Cap {}' > "$proj/Assets/Scripts/Cap/Cap.cs"
for i in $(seq -w 1 14); do
  gfx "$t/Cap/Fixture$i.cs" ExampleGame.Cap.Tests "Fixture$i" Gfx
  printf '// Cap\n' >> "$t/Cap/Fixture$i.cs"
done
GIT_AUTHOR_DATE=2021-01-01T00:00:00Z GIT_COMMITTER_DATE=2021-01-01T00:00:00Z commit cap-fixtures
# Commit Fixture01 later than all others; leave it clean so an older-dated dirty fixture still ranks first.
echo '// newest committed' >> "$t/Cap/Fixture01.cs"
GIT_AUTHOR_DATE=2021-01-02T00:00:00Z GIT_COMMITTER_DATE=2021-01-02T00:00:00Z commit newest-fixture
# A newer Gfx fixture in the same folder is not a candidate unless its source mentions the changed class.
gfx "$t/Cap/UnrelatedTests.cs" ExampleGame.Other.Tests UnrelatedTests Gfx
GIT_AUTHOR_DATE=2021-01-03T00:00:00Z GIT_COMMITTER_DATE=2021-01-03T00:00:00Z commit unrelated-fixture
for i in $(seq -w 2 14); do
  echo '// dirty' >> "$t/Cap/Fixture$i.cs"
  touch -t "2020010100${i}.00" "$t/Cap/Fixture$i.cs"
done
echo '// changed runtime' >> "$proj/Assets/Scripts/Cap/Cap.cs"
pick
expected="$(for i in $(seq 14 -1 3); do printf 'ExampleGame.Cap.Tests.Fixture%02d\n' "$i"; done)"
check "default cap is 12; overflow chooses newest matching dirty fixtures in descending order" \
  '[ "$(wc -l < "$tmp/picked")" = 12 ] && [ "$(< "$tmp/picked")" = "$expected" ]'
check "overflow logs the fallback and cap on stderr, without contaminating stdout" \
  'grep -q "14 matching Gfx fixtures exceed TEST_PR_GFX_MAX=12; fallback" "$tmp/pick-err" && ! grep -qE "why:|selected|fallback" "$tmp/picked"'
TEST_PR_GFX_MAX=2 pick
check "custom cap also orders by recency, not class name" \
  '[ "$(< "$tmp/picked")" = "$(printf "ExampleGame.Cap.Tests.Fixture14\nExampleGame.Cap.Tests.Fixture13")" ]'
TEST_PR_GFX_MAX=14 pick
check "at the cap, no fallback: all matching classes in normal sorted order" \
  '[ "$(wc -l < "$tmp/picked")" = 14 ] && [ "$(head -n1 "$tmp/picked")" = ExampleGame.Cap.Tests.Fixture01 ] && ! grep -q fallback "$tmp/pick-err"'
# Equal mtimes have a stable class-name tie-break. A tracked dirty file and an untracked file share that policy.
git -C "$proj" checkout -q -- Assets/Tests/EditMode/Cap
printf '// dirty\n' >> "$t/Cap/Fixture02.cs"
gfx "$t/Cap/Fixture15.cs" ExampleGame.Cap.Tests Fixture15 Gfx
printf '// Cap\n' >> "$t/Cap/Fixture15.cs"
touch -t 202001010100.00 "$t/Cap/Fixture02.cs" "$t/Cap/Fixture15.cs"
TEST_PR_GFX_MAX=2 pick
check "dirty and untracked sources outrank clean committed sources; ties sort by class name" \
  '[ "$(< "$tmp/picked")" = "$(printf "ExampleGame.Cap.Tests.Fixture02\nExampleGame.Cap.Tests.Fixture15")" ]'
rm "$t/Cap/Fixture15.cs"
git -C "$proj" checkout -q -- Assets/Tests/EditMode/Cap
TEST_PR_GFX_MAX=1 pick
check "clean matching fixtures use commit recency, never a newer nonmatching fixture" '[ "$(< "$tmp/picked")" = ExampleGame.Cap.Tests.Fixture01 ]'
TEST_PR_GFX_MAX=0 pick
check "a zero cap selects no fixtures and explains the fallback" '[ ! -s "$tmp/picked" ] && grep -q TEST_PR_GFX_MAX=0 "$tmp/pick-err"'
TEST_PR_GFX_MAX=invalid pick
check "invalid cap falls back to the default" '[ "$(wc -l < "$tmp/picked")" = 12 ] && grep -q "invalid TEST_PR_GFX_MAX" "$tmp/pick-err"'
git -C "$proj" checkout -q -- Assets/Scripts/Cap/Cap.cs

# --- options and failures ---------------------------------------------------------------------------------------------
pr -logLevel x
check "extra Unity args go to both passes; base stays origin/main" \
  '[ "$(wc -l < "$tmp/runs")" = 2 ] && pure_run | grep -q -- "-logLevel x" && gfx_run | grep -q -- "-logLevel x"'
pr -testFilter Foo
check "test pr with -testFilter is refused before any editor run" '[ "$rc" != 0 ] && [ ! -s "$tmp/runs" ] && grep -q "use test editmode" "$tmp/err"'
pr no-such-ref
check "unknown base fails clearly" '[ "$rc" != 0 ] && grep -q "no merge-base between no-such-ref and HEAD" "$tmp/err"'
: > "$tmp/runs"; rc=0; FAKE_FAILS=ExampleGame.Props.Tests.RulesTests.A bash "$script" test pr 2>"$tmp/err" || rc=$?
check "pure-pass failure still runs Gfx and fails the run" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ]'
: > "$tmp/runs"; rc=0; EDITMODE_GFX=0 bash "$script" test pr 2>"$tmp/err" || rc=$?
check "EDITMODE_GFX=0 skips Gfx" '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'

# --- upfront estimate and count-scaled budget (no editor) ------------------------------------------------------------
(
  . "$(dirname "$script")/test-passes.sh"
  log() { printf '%s\n' "$*"; }
  many="$(for i in $(seq 46); do echo "X.Fixture$i"; done)"
  UNITY_GFX_TIMEOUT=3600 TEST_PR_TIMEOUT_EXPLICIT= pr_gfx_budget "$many" > "$tmp/budget"
  grep -q 'selected 46 Gfx fixtures; estimated tests 4140 s.*timeout 6720 s' "$tmp/budget"
) && budget_ok=1 || budget_ok=0
check "46 selected fixtures scale the default budget beyond startup plus the observed 60-minute test time" '[ "$budget_ok" = 1 ]'
(
  . "$(dirname "$script")/test-passes.sh"
  log() { printf '%s\n' "$*"; }
  UNITY_GFX_TIMEOUT=77 TEST_PR_TIMEOUT_EXPLICIT=77 pr_gfx_budget X.Fixture > "$tmp/budget"
  grep -q 'selected 1 Gfx fixtures; estimated tests 90 s.*timeout 77 s' "$tmp/budget"
) && budget_ok=1 || budget_ok=0
check "explicit caller timeout still wins over the scaled default" '[ "$budget_ok" = 1 ]'
pr
check "test pr prints selection size and estimate before pure starts" \
  'awk "/selected [0-9]+ Gfx fixtures; estimated tests/ { estimate=NR } /stage pure-pass start/ { exit !(estimate && estimate < NR) }" "$tmp/err"'

# --- test editmode is unchanged ---------------------------------------------------------------------------------------
: > "$tmp/runs"; bash "$script" test editmode 2>"$tmp/err"
check "test editmode still runs full Gfx (no -testFilter)" \
  '[ "$(wc -l < "$tmp/runs")" = 2 ] && gfx_run | grep -q -- "-testCategory Gfx" && ! grep -q -- -testFilter "$tmp/runs"'

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

# Editor roots may sit inside the scripts root: builder references must still
# search all tests, not an inferred Editor area (which is absent here).
mv "$proj/Assets/_Project/Editor" "$proj/Assets/_Project/Scripts/Editor"
jq '.tests.editorRoot = "Assets/_Project/Scripts/Editor"' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
commit nested-editor-layout
echo '// changed nested builder' >> "$proj/Assets/_Project/Scripts/Editor/World/Court/CourtBuilder.cs"
pick
check "nested editor root takes precedence over scripts-area selection" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Park.Tests.HoopTests ] && grep -q "why: references builder CourtBuilder" "$tmp/pick-err"'
rm "$proj/Assets/_Project/Scripts/Editor/World/Court/CourtBuilder.cs"
pick
check "deleted nested editor builder still searches fixtures outside the inferred area" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Park.Tests.HoopTests ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
