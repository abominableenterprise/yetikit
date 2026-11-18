#!/usr/bin/env bash
# Synthetic PR-selection regressions: literal Git paths and builder keys.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

# Force Git's default quoting even if the host has disabled it. A literal
# backslash also exposes escaping in the builder-key lookup independently.
git -C "$proj" config core.quotePath true
root='Assets/Étage'
edit="$root/Essais"
scripts="$root/Sources"
editor="$root/Éditeur"
builder_dir="$editor/"'Literal\new'
builder="$builder_dir/Mapped.cs"
mkdir -p "$proj/$edit/Area" "$proj/$scripts/Area" "$proj/$builder_dir"
gfx "$proj/$edit/Area/ChangedTests.cs" Fixture.Tests ChangedTests Gfx
gfx "$proj/$edit/Area/RuntimeTests.cs" Fixture.Tests RuntimeTests Gfx
gfx "$proj/$edit/Area/BuilderTests.cs" Fixture.Tests BuilderTests Gfx
printf '// RuntimeType, NewRuntimeType\n' >> "$proj/$edit/Area/RuntimeTests.cs"
printf 'class RuntimeType {}\n' > "$proj/$scripts/Area/RuntimeType.cs"
printf 'class Mapped {}\n' > "$proj/$builder"
jq --arg root "$root" --arg edit "$edit" --arg scripts "$scripts" --arg editor "$editor" --arg builder "$builder" '
  .tests = {root: $root, editModeRoot: $edit, scriptsRoot: $scripts, editorRoot: $editor,
    builderFixtures: {("./" + $builder): ["Fixture.Tests.BuilderTests"],
      (($builder | sub("/"; "//"))): ["Fixture.Tests.ChangedTests"]}}' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
commit literal-roots

echo '// edited' >> "$proj/$edit/Area/ChangedTests.cs"
pick
check 'tracked test under a non-ASCII EditMode root is selected directly' \
  '[ "$(< "$tmp/picked")" = Fixture.Tests.ChangedTests ] && grep -Fq "why: changed test $edit/Area/ChangedTests.cs" "$tmp/pick-err"'
git -C "$proj" restore -- "$edit/Area/ChangedTests.cs"

gfx "$proj/$edit/Area/NewTests.cs" Fixture.Tests NewTests Gfx
pick
check 'untracked test under a non-ASCII EditMode root is selected directly' \
  '[ "$(< "$tmp/picked")" = Fixture.Tests.NewTests ] && grep -Fq "why: changed test $edit/Area/NewTests.cs" "$tmp/pick-err"'
rm "$proj/$edit/Area/NewTests.cs"

echo '// edited' >> "$proj/$scripts/Area/RuntimeType.cs"
pick
check 'tracked runtime source under a non-ASCII scripts root finds its referencing fixture' \
  '[ "$(< "$tmp/picked")" = Fixture.Tests.RuntimeTests ] && grep -Fq "why: references RuntimeType from $scripts/Area/RuntimeType.cs" "$tmp/pick-err"'
git -C "$proj" restore -- "$scripts/Area/RuntimeType.cs"

printf 'class NewRuntimeType {}\n' > "$proj/$scripts/Area/NewRuntimeType.cs"
pick
check 'untracked runtime source under a non-ASCII scripts root finds its referencing fixture' \
  '[ "$(< "$tmp/picked")" = Fixture.Tests.RuntimeTests ] && grep -Fq "why: references NewRuntimeType from $scripts/Area/NewRuntimeType.cs" "$tmp/pick-err"'
rm "$proj/$scripts/Area/NewRuntimeType.cs"

echo '// edited' >> "$proj/$builder"
pick
check 'tracked builder resolves and merges equivalent configured keys without a source reference' \
  '[ "$(< "$tmp/picked")" = $'"'"'Fixture.Tests.BuilderTests\nFixture.Tests.ChangedTests'"'"' ] && grep -Fq "why: configured builder dependency" "$tmp/pick-err"'
# Recreate the same builder path untracked against a base that does not contain it.
git -C "$proj" rm -qf -- "$builder"
commit remove-builder
mkdir -p "$proj/$builder_dir"
printf 'class Mapped {}\n' > "$proj/$builder"
pick
check 'untracked builder resolves equivalent configured keys without a source reference' \
  '[ "$(< "$tmp/picked")" = $'"'"'Fixture.Tests.BuilderTests\nFixture.Tests.ChangedTests'"'"' ] && grep -Fq "why: configured builder dependency" "$tmp/pick-err"'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
