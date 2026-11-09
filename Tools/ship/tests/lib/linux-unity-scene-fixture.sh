#!/usr/bin/env bash
# Shared synthetic editor and temp git project for topical scene regressions.
# Fixture helpers reproduce setup mutations without replaying earlier scene commands.
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shm"
export SHM_DIR="$tmp/shm"   # Never clean the host's /dev/shm.
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

proj="$tmp/proj"; dir="$proj/Assets/Scenes/GeneratedScene"; mkdir -p "$dir" "$tmp/unity/Editor"
. "$(dirname "${BASH_SOURCE[0]}")/fixture.sh"
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

scene_outside_fixture() {
  sed -i 's/s\/m_BounceScale: 1\/m_BounceScale: 2\//s\/lightmap: 0\/lightmap: 1\//' "$tmp/unity/Editor/Unity"
  sed -i 's|"\$d/GeneratedSceneLighting.lighting"|"$d/Lightmap-0_comp_light.exr.meta"|' "$tmp/unity/Editor/Unity"
}

scene_props_fixture() {
  props="$proj/Assets/Art/Props"; mkdir -p "$props/Cup" "$props/Soda"
  echo prefab > "$props/Cup/Cup.prefab"; echo prefab > "$props/Soda/Soda.prefab"
  git -C "$proj" add -A && git -C "$proj" -c user.name=t -c user.email=t@t commit -qm props
  sed -i 's|^echo "ran \$m" > "\$l"$|&\n[ "$m" = ExampleGame.World.Editor.PropSetup.Run ] \&\& for x in Cup Soda; do echo repacked > "$p/Assets/Art/Props/$x/$x.prefab"; done|' \
    "$tmp/unity/Editor/Unity"
}
