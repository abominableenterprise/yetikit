#!/usr/bin/env bash
# Tests that `linux-unity.sh scene` keeps real generated changes (lighting asset, developer .meta edits) and reverts
# only the bake-only platformSettings change to Lightmap-*.exr.meta. Uses a stub editor and a temp git project.
# Run: bash Tools/ship/tests/linux-unity-scene.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shm"
export SHM_DIR="$tmp/shm"   # Never clean the host's /dev/shm.
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

proj="$tmp/proj"; dir="$proj/Assets/Scenes/GeneratedScene"; mkdir -p "$dir" "$tmp/unity/Editor"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
lighting="$dir/GeneratedSceneLighting.lighting"
meta() { printf 'TextureImporter:\n  lightmap: 0\n  platformSettings:\n  - buildTarget: DefaultTexturePlatform\n  spriteSheet:\n    sprites: []\n  userData: %s\n' "$1"; }
printf 'LightingSettings:\n  m_BounceScale: 1\n' > "$lighting"
for i in 0 1 2; do meta "" > "$dir/Lightmap-${i}_comp_light.exr.meta"; done
git -C "$proj" init -q && git -C "$proj" add -A
git -C "$proj" -c user.name=t -c user.email=t@t commit -qm base

# Stub editor: WorldSceneBuilder.Run changes a lighting setting and adds a platform override to every lightmap .meta,
# like the Linux bake does.
cat > "$tmp/unity/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -projectPath) p="$2"; shift ;; -executeMethod) m="$2"; shift ;; -logFile) l="$2"; shift ;; esac; shift
done
echo "ran $m" > "$l"
if [ "$m" = ExampleGame.World.Editor.WorldSceneBuilder.Run ]; then
  d="$p/Assets/Scenes/GeneratedScene"
  sed -i 's/m_BounceScale: 1/m_BounceScale: 2/' "$d/GeneratedSceneLighting.lighting"
  for f in "$d"/Lightmap-*.exr.meta; do
    sed -i 's/^  - buildTarget: DefaultTexturePlatform.*$/&\n  - buildTarget: Standalone/' "$f"
  done
fi
EOF
chmod +x "$tmp/unity/Editor/Unity"
printf '<root><License id="Terms"><StopDate Value="" /></License><Signature>x</Signature></root>\n' > "$tmp/ulf"
# The temp repo has no origin/main: HEAD is the base (no branch changes), as in a fresh task branch.
export NOISE_BASE=HEAD
# Stub xvfb-run: drop its own options and run the command directly.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\n[ "$1" = -a ] && shift\n[ "$1" = -s ] && shift 2\nexec "$@"\n' > "$tmp/bin/xvfb-run"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/nohup"
chmod +x "$tmp/bin/xvfb-run" "$tmp/bin/nohup"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT
export PATH="$tmp/bin:$PATH" UNITY_USERNAME=u UNITY_PASSWORD=p

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

# scene --keep resolves the path from the caller's directory: PropSetup.Run re-packs two prop prefabs (no source
# changed, so both are noise); the one passed as ./Cup.prefab from its own directory survives.
git -C "$proj" checkout -q -- .
props="$proj/Assets/Art/Props"; mkdir -p "$props/Cup" "$props/Soda"
echo prefab > "$props/Cup/Cup.prefab"; echo prefab > "$props/Soda/Soda.prefab"
git -C "$proj" add -A && git -C "$proj" -c user.name=t -c user.email=t@t commit -qm props
sed -i 's|^echo "ran \$m" > "\$l"$|&\n[ "$m" = ExampleGame.World.Editor.PropSetup.Run ] \&\& for x in Cup Soda; do echo repacked > "$p/Assets/Art/Props/$x/$x.prefab"; done|' \
  "$tmp/unity/Editor/Unity"
(cd "$props/Cup" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --keep ./Cup.prefab) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --keep ./x from a subdirectory keeps that prefab" 'grep -q repacked "$props/Cup/Cup.prefab"'
check "scene reverts the other re-packed prefab" 'git -C "$proj" diff --quiet -- "$props/Soda/Soda.prefab"'
rc=0; (cd "$tmp" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --keep ./nowhere) 2>/dev/null || rc=$?
check "scene --keep outside the project fails before building" '[ "$rc" != 0 ]'

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

# scene --area <Area>: PropSetup then BuildAreaFromCommandLine with -area <Area> (no full build, bake or stats).
git -C "$proj" checkout -q -- .
sed -i 's|^echo "ran \$m" > "\$l"$|echo "ran $m $*" >> "$p/../calls"\n&|' "$tmp/unity/Editor/Unity"
sed -i 's|^while \[ \$# -gt 0 \]; do$|all="$*"\n&|; s|echo "ran \$m \$\*"|echo "ran $m $all"|' "$tmp/unity/Editor/Unity"
rm -f "$tmp/calls"
(cd "$proj" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --area Court --area Pigeons) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --area runs PropSetup then BuildAreaFromCommandLine with each -area" \
  'grep -q "PropSetup.Run" "$tmp/calls" && grep -q "BuildAreaFromCommandLine.*-area Court -area Pigeons" "$tmp/calls"'
check "scene --area skips the full build and stats" '! grep -q "WorldSceneBuilder.Run\|WorldStats.Run" "$tmp/calls"'
rc=0; (cd "$proj" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --area '../x') 2>/dev/null || rc=$?
check "scene --area rejects a non-name" '[ "$rc" != 0 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
