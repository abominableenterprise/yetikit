#!/usr/bin/env bash
# test-passes.sh: runtime files may declare several types, none named after the file.
# Fixture C# lives only in a temporary repo; no editor is invoked.
set -euo pipefail
helper="$(cd "$(dirname "$0")/.." && pwd)/test-passes.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$tmp"
helper="$tmp/Tools/ship/test-passes.sh"
cd "$tmp"
git init -q
git config user.email test@example.com
git config user.name Test
mkdir -p Assets/Scripts/Pigeons Assets/Tests/EditMode/{Pigeons,Other}
cat > Assets/Scripts/Pigeons/PigeonTypes.cs <<'CS'
namespace Birds {
    public class PigeonBrain { }
    public readonly struct PigeonEvent { }
    public enum PigeonState { Idle }
    public interface IPigeon { }
    public record PigeonSnapshot(int Count);
    public record struct PigeonPosition(float X);
    public record class PigeonFlight(float Speed);
    // class CommentOnly { }
    /* enum BlockCommentOnly { Idle } */
    class TextHolder { string text = "interface StringOnly {}"; }
}
CS
fixture() {
  printf 'namespace Tests\n{\n    [Category("Gfx")]\n    public class %s { %s value; }\n}\n' "$2" "$3" > "$1"
}
for type in PigeonBrain PigeonEvent PigeonState IPigeon PigeonSnapshot PigeonPosition PigeonFlight; do
  fixture "Assets/Tests/EditMode/Pigeons/${type}Tests.cs" "${type}Tests" "$type"
done
fixture Assets/Tests/EditMode/Pigeons/BasenameTests.cs BasenameTests PigeonTypes
fixture Assets/Tests/EditMode/Pigeons/SubstringTests.cs SubstringTests PigeonEventSuffix
fixture Assets/Tests/EditMode/Pigeons/CommentTests.cs CommentTests CommentOnly
fixture Assets/Tests/EditMode/Pigeons/BlockTests.cs BlockTests BlockCommentOnly
fixture Assets/Tests/EditMode/Pigeons/StringTests.cs StringTests StringOnly
fixture Assets/Tests/EditMode/Other/EscapeTests.cs EscapeTests PigeonEvent
git add .; git commit -qm base
base="$(git rev-parse HEAD)"
printf '// changed\n' >> Assets/Scripts/Pigeons/PigeonTypes.cs
. "$tmp/Tools/ship/lib/config.sh"
ship_config_load
. "$helper"
pr_gfx_fixtures "$base" > picked 2> reasons
for type in PigeonBrain PigeonEvent PigeonState IPigeon PigeonSnapshot PigeonPosition PigeonFlight; do
  grep -qx "Tests.${type}Tests" picked || { echo "FAIL: missing declared type $type"; exit 1; }
done
grep -qx Tests.BasenameTests picked
[ "$(wc -l < picked)" -eq 8 ] || { echo 'FAIL: selection escaped area, matched substring, comment or string'; exit 1; }
grep -q 'why: references .*PigeonEvent.* from Assets/Scripts/Pigeons/PigeonTypes.cs' reasons
! grep -qE 'why:|selected' picked
echo 'ok   all declared type forms plus basename select area-local whole-word references with explanations'

# The type expansion must still pass through the existing twelve-fixture cap.
for n in $(seq 1 14); do
  fixture "Assets/Tests/EditMode/Pigeons/Extra$n.cs" "Extra$n" PigeonEvent
done
pr_gfx_fixtures "$base" > picked 2> reasons
[ "$(wc -l < picked)" -eq 12 ]
grep -q '22 matching Gfx fixtures exceed TEST_PR_GFX_MAX=12; fallback' reasons
echo 'ok   declared-type matches retain the default twelve-fixture cap'

# A deleted source still has the pre-existing basename fallback.
git add Assets; git commit -qm extras
base="$(git rev-parse HEAD)"
rm Assets/Scripts/Pigeons/PigeonTypes.cs
pr_gfx_fixtures "$base" > picked 2> reasons
[ "$(< picked)" = Tests.BasenameTests ]
echo 'ok   deleted runtime sources retain basename matching'
