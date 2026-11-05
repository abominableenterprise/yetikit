#!/usr/bin/env bash
# Exact-path TMP serialization backstop; all git writes are in a disposable repository.
set -euo pipefail
lib="${SCENE_NOISE_LIB:-$(cd "$(dirname "$0")/.." && pwd)/scene-noise.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NOISE_BASE=HEAD
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$tmp/project"
cd "$PROJECT"
font='Assets/TextMesh Pro/Resources/Fonts & Materials/LiberationSans SDF.asset'
other='Assets/TextMesh Pro/Resources/Fonts & Materials/Other.asset'
meta="$font.meta"
# Multiple consumer-selected paths, including Git pathspec metacharacters, are literal.
extra='Assets/Fonts/Static [test].asset'
jq --arg font "$font" --arg extra "$extra" '.noise.fontAssetPaths = [$font, $extra]' yetikit.json > "$tmp/config.json"
mv "$tmp/config.json" yetikit.json
. "$PROJECT/Tools/ship/lib/config.sh"
ship_config_load
. "$lib"
git init -q
mkdir -p "$(dirname "$extra")"
printf 'static font\n' > "$extra"
mkdir -p "$(dirname "$font")"
printf 'MonoBehaviour:\n  m_AtlasPopulationMode: 0\n  m_UsedGlyphRects: []\n' > "$font"
printf 'other\n' > "$other"; printf 'guid: font\n' > "$meta"
git add .; git -c user.name=t -c user.email=t@t commit -qm base
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
clean() { git diff --quiet HEAD -- ":(literal)$1"; }
reset_case() { git reset -q --hard HEAD; }
serialize() { printf '  m_EditorClassIdentifier: changed\n  m_UsedGlyphRects: [1]\n' >> "$font"; }
for revert in revert_run_noise revert_editor_noise revert_scene_noise; do
  reset_case
  before="$(noise_dirty_files)"; serialize
  "$revert" "$before" >/dev/null 2>&1
  check "$revert reverts serialization of the previously clean static font" 'clean "$font"'
  printf 'serialization\n' >> "$extra"
  "$revert" '' >/dev/null 2>&1
  check "$revert supports multiple literal font paths" 'clean "$extra"'

  for keep in "$font" 'Assets/TextMesh Pro'; do
    reset_case; serialize
    "$revert" '' "$keep" >/dev/null 2>&1
    check "$revert protects --keep $keep" '! clean "$font"'
  done

  reset_case; serialize; before="$(noise_dirty_files)"; printf 'later editor change\n' >> "$font"
  expected="$(git hash-object "$font")"
  "$revert" "$before" >/dev/null 2>&1
  check "$revert preserves pre-dirty font byte-for-byte" '[ "$(git hash-object "$font")" = "$expected" ]'

  # Staged edit with working copy restored to HEAD must still count as pre-dirty.
  reset_case; serialize; git add -- "$font"
  staged="$(git rev-parse ":$font")"
  git show "HEAD:$font" > "$font"
  before="$(noise_dirty_files)"; serialize; printf 'after staged\n' >> "$font"
  expected="$(git hash-object "$font")"
  "$revert" "$before" >/dev/null 2>&1
  check "$revert preserves staged index and working copy" \
    '[ "$(git rev-parse ":$font")" = "$staged" ] && [ "$(git hash-object "$font")" = "$expected" ]'

  reset_case; before="$(noise_dirty_files)"; rm -- "$font"
  "$revert" "$before" >/dev/null 2>&1
  check "$revert does not resurrect a deleted font" '[ ! -e "$font" ]'

  reset_case; printf 'real edit\n' >> "$other"; printf 'real guid edit\n' >> "$meta"
  "$revert" '' >/dev/null 2>&1
  check "$revert touches neither other font assets nor the font meta" '! clean "$other" && ! clean "$meta"'
done
# Recovery CLI uses the same backstop and keep protections (spaces and ampersand in the path).
reset_case; serialize
bash "$lib" --run --keep "$font" >/dev/null 2>&1
check 'standalone --run honors exact font --keep' '! clean "$font"'
bash "$lib" --run >/dev/null 2>&1
check 'standalone --run cleans the font' 'clean "$font"'
# Consumers that omit the key or opt into no fonts retain the old conservative behavior.
for config in 'del(.noise.fontAssetPaths)' '.noise.fontAssetPaths = []'; do
  reset_case; serialize
  jq "$config" yetikit.json > "$tmp/config.json"
  mv "$tmp/config.json" yetikit.json
  bash "$lib" --run >/dev/null 2>&1
  check "$config disables font cleanup" '! clean "$font"'
done
echo "$fails failure(s)"; [ "$fails" = 0 ]
