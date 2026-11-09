#!/usr/bin/env bash
# Synthetic scene regressions with an isolated editor and project.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-scene-fixture.sh"

scene_outside_fixture
scene_props_fixture
# #120: --keep reaches the lightmap .meta revert. The bake adds a platformSettings-only override to every clean
# Lightmap-*.exr.meta; the kept one (file, or a directory spelling) survives, the others are still reverted.
git -C "$proj" checkout -q -- .
(cd "$dir" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --keep ./Lightmap-1_comp_light.exr.meta) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --keep keeps a platformSettings-only lightmap .meta change" \
  'grep -q Standalone "$dir/Lightmap-1_comp_light.exr.meta" && grep -q "keeping Assets/Scenes/GeneratedScene/Lightmap-1_comp_light.exr.meta (--keep)" "$tmp/err"'
check "scene --keep <one .meta> still reverts the other bake-only .meta files" \
  'git -C "$proj" diff --quiet -- "$dir/Lightmap-2_comp_light.exr.meta"'
git -C "$proj" checkout -q -- .
(cd "$proj" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --keep Assets/Scenes/GeneratedScene/) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --keep <lightmap dir>/ keeps every platformSettings-only .meta change" \
  'grep -q Standalone "$dir/Lightmap-1_comp_light.exr.meta" && grep -q Standalone "$dir/Lightmap-2_comp_light.exr.meta"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
