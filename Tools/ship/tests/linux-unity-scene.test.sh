#!/usr/bin/env bash
# Synthetic scene regressions with an isolated editor and project.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-scene-fixture.sh"

# Before the run: Lightmap-1 has a developer edit outside platformSettings; Lightmap-2 one inside it.
sed -i 's/userData: $/userData: mine/' "$dir/Lightmap-1_comp_light.exr.meta"
sed -i 's/DefaultTexturePlatform/DefaultTexturePlatform # tuned/' "$dir/Lightmap-2_comp_light.exr.meta"

PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" bash "$script" scene 2>"$tmp/err" \
  || { cat "$tmp/err"; exit 1; }

check "scene keeps a real lighting-setting change" 'grep -q "m_BounceScale: 2" "$lighting"'
check "bake-only platformSettings change on a clean .meta is reverted" \
  'git -C "$proj" diff --quiet -- "$dir/Lightmap-0_comp_light.exr.meta"'
check "developer edit outside platformSettings survives" \
  'grep -q "userData: mine" "$dir/Lightmap-1_comp_light.exr.meta"'
check "a .meta edited before scene is left alone" \
  'grep -q "tuned" "$dir/Lightmap-2_comp_light.exr.meta" && grep -q Standalone "$dir/Lightmap-2_comp_light.exr.meta"'

# A clean .meta whose bake change reaches outside platformSettings is kept, not reverted.
git -C "$proj" checkout -q -- .
sed -i 's/s\/m_BounceScale: 1\/m_BounceScale: 2\//s\/lightmap: 0\/lightmap: 1\//' "$tmp/unity/Editor/Unity"
sed -i 's|"\$d/GeneratedSceneLighting.lighting"|"$d/Lightmap-0_comp_light.exr.meta"|' "$tmp/unity/Editor/Unity"
PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" bash "$script" scene 2>"$tmp/err" \
  || { cat "$tmp/err"; exit 1; }
check "a .meta changed outside platformSettings by the run is kept" \
  'grep -q "lightmap: 1" "$dir/Lightmap-0_comp_light.exr.meta"'
check "the other clean .meta files are still reverted" \
  'git -C "$proj" diff --quiet -- "$dir/Lightmap-1_comp_light.exr.meta" "$dir/Lightmap-2_comp_light.exr.meta"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
