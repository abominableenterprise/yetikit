#!/usr/bin/env bash
# Exact-path _SPECULAR_COLOR cleanup in scene and open/test paths; fake files only, no Unity.
# SCENE_NOISE_LIB can point at a baseline copy for failing-first verification.
set -euo pipefail
lib="${SCENE_NOISE_LIB:-$(cd "$(dirname "$0")/.." && pwd)/scene-noise.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
export NOISE_BASE=HEAD
proj="$tmp/proj"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
cd "$proj"
git init -q
. "$proj/Tools/ship/lib/config.sh"
ship_config_load
. "$lib"
f="$(ship_config_get '.noise.specularMaterialPath')"
mkdir -p "$(dirname "$f")"
other=Assets/Art/World/Materials/Other.mat
fixture() {
  printf 'Material:\n  m_Shader: {fileID: 4800000}\n  m_ValidKeywords:%s\n  m_InvalidKeywords:%s\n  m_LightmapFlags: %s\n' "${1:- []}" "${2:- []}" "${3:-4}"
}
fixture > "$f"
fixture > "$other"
git add -A
git -c user.name=t -c user.email=t@t commit -qm base
clean() { git diff --quiet HEAD -- "$1"; }
reset() { git checkout -q -- .; noise_dirty_files > "$tmp/before"; }
cleanup() { bash "$lib" "${mode[@]}" --before "$tmp/before" "$@" > "$tmp/out" 2>&1; }
for path in scene open/test; do
  mode=()
  [ "$path" = scene ] || mode=(--run)
  for field in valid invalid; do
    reset
    if [ "$field" = valid ]; then fixture $'\n  - _SPECULAR_COLOR' > "$f"
    else fixture ' []' $'\n  - _SPECULAR_COLOR' > "$f"; fi
    cleanup
    check "$path: _SPECULAR_COLOR-only $field keyword addition is reverted" \
      'clean "$f" && grep -q "reverting $f (only _SPECULAR_COLOR keyword)" "$tmp/out"'
  done

  reset
  fixture $'\n  - _SPECULAR_COLOR' ' []' 0 > "$f"
  cleanup
  check "$path: another material property change is kept" '! clean "$f"'

  reset
  fixture $'\n  - _SPECULAR_COLOR\n  - _NORMALMAP' > "$f"
  cleanup
  check "$path: another keyword change is kept" '! clean "$f"'

  reset
  fixture $'\n  - _SPECULAR_COLOR\n  - _SPECULAR_COLOR' > "$f"
  cleanup
  check "$path: duplicate specular keyword is kept conservatively" '! clean "$f"'

  reset
  fixture $'\n  - _SPECULAR_COLOR' > "$other"
  cleanup
  check "$path: another material with identical noise is not allowlisted" '! clean "$other"'

  reset
  fixture ' []' ' []' 0 > "$f"
  noise_dirty_files > "$tmp/before"
  fixture $'\n  - _SPECULAR_COLOR' ' []' 0 > "$f"
  cp "$f" "$tmp/expected"
  cleanup
  check "$path: pre-dirty real edit and new keyword are both kept" 'cmp -s "$f" "$tmp/expected"'

  reset
  fixture $'\n  - _SPECULAR_COLOR' > "$f"
  noise_dirty_files > "$tmp/before"
  cleanup
  check "$path: pre-dirty keyword-only edit is kept" '! clean "$f"'

  for keep in "$f" Assets/Art/World/Materials; do
    reset
    fixture $'\n  - _SPECULAR_COLOR' > "$f"
    cleanup --keep "$keep"
    check "$path: --keep $keep protects keyword noise" '! clean "$f"'
  done

  reset
  rm "$f"
  cleanup
  check "$path: deleted material is kept deleted" '[ ! -e "$f" ]'

  # The index may have a real edit while the working tree matches HEAD at snapshot time.
  reset
  fixture ' []' ' []' 0 > "$f"
  git add -- "$f"
  git show ":$f" > "$tmp/staged"
  git show "HEAD:$f" > "$f"
  noise_dirty_files > "$tmp/before"
  fixture $'\n  - _SPECULAR_COLOR' > "$f"
  cp "$f" "$tmp/expected"
  cleanup
  git show ":$f" > "$tmp/staged-after"
  check "$path: staged pre-dirty material and working file are preserved" \
    'cmp -s "$f" "$tmp/expected" && cmp -s "$tmp/staged" "$tmp/staged-after"'
  git reset -q HEAD -- "$f"
done

# Also cover removal/migration when the committed material already has this keyword, and ensure
# unrelated existing keywords remain byte-identical rather than sorting/normalizing the whole list.
reset
fixture $'\n  - _NORMALMAP\n  - _SPECULAR_COLOR' > "$f"
git add -- "$f"
git -c user.name=t -c user.email=t@t commit -qm keyword
for path in scene open/test; do
  mode=()
  [ "$path" = scene ] || mode=(--run)
  for invalid in ' []' $'\n  - _SPECULAR_COLOR'; do
    reset
    fixture $'\n  - _NORMALMAP' "$invalid" > "$f"
    cleanup
    check "$path: specular removal/migration preserves other keyword and is reverted" 'clean "$f"'
  done
  reset
  fixture $'\n  - _EMISSION' > "$f"
  cleanup
  check "$path: removal with a real existing-keyword edit is kept" '! clean "$f"'
done
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
