#!/usr/bin/env bash
# Focused regressions for linux-unity.sh, config.sh and scene-noise.sh review fixes.
set -euo pipefail
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PROJECT="$tmp/project" SHM_DIR="$tmp/shm" UNITY_ROOT="$tmp/unity"
mkdir -p "$PROJECT" "$SHM_DIR" "$UNITY_ROOT/Editor"
cat > "$PROJECT/yetikit.json" <<'JSON'
{
  "schema": 1,
  "unityVersion": "6000.6.6f1",
  "build": {
    "devMethod": "Fixture.Dev",
    "releaseMethod": "Fixture.Release",
    "apkPath": "build/fixture.apk"
  },
  "scene": {
    "steps": ["Fixture.Scene"],
    "areaStep": "Fixture.Area",
    "lightmapDir": "./Assets//Lightmaps/",
    "areasDir": "./Assets//Art/Areas/",
    "keepPaths": ["./Assets//Art/Kept/"]
  },
  "noise": {
    "propsDir": "./Assets//Art/Props/",
    "atlasPath": "./Assets//Art/atlas.png",
    "repackRegex": "^Assets/Art/Areas/([A-Za-z]+)\\.prefab$"
  }
}
JSON
source "$tool_dir/linux-unity.sh"
. "$tool_dir/tests/lib/fixture.sh"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/process-view:$PATH" SHIP_FIXTURE_PIDS=''
failures=0
check() {
  if "$@"; then printf 'PASS: %s\n' "$1"; else printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); fi
}
canonical_paths() {
  [ "$(ship_config_get '.scene.areasDir')" = Assets/Art/Areas ] &&
    [ "$(ship_config_get '.scene.keepPaths[]?')" = Assets/Art/Kept ] &&
    [ "$(ship_config_get '.scene.lightmapDir // empty')" = Assets/Lightmaps ] &&
    [ "$NOISE_PROPS_DIR" = Assets/Art/Props ] &&
    [ "$NOISE_ATLAS" = Assets/Art/atlas.png ] &&
    [ "$(ship_config_get '.scene.areasDir + "/X.prefab"')" = Assets/Art/Areas/X.prefab ]
}
check canonical_paths

# A texture edit must protect regenerated atlas data with noncanonical config spelling.
cd "$PROJECT"
git init -q
git config user.name Fixture
git config user.email fixture@example.invalid
mkdir -p Assets/Art/{Props,Kept,Areas}
printf 'original\n' > Assets/Art/atlas.png
printf 'texture\n' > Assets/Art/Props/source.png
printf '  m_Floats: []\n' > Assets/Art/Kept/protected.mat
printf '  m_Floats: []\n' > Assets/Art/cli.mat
printf '  m_Floats: []\n' > Assets/Art/noise.mat
printf 'original\n' > Assets/Art/Areas/X.prefab
git add . && git commit -qm 'Synthetic cleanup fixture'
export NOISE_BASE=HEAD
printf 'regenerated\n' > Assets/Art/atlas.png
printf 'edited\n' > Assets/Art/Props/source.png
source_protects_atlas() {
  noise_sources_changed Assets/Art/Props/source.png &&
    revert_editor_noise '' && grep -qx regenerated Assets/Art/atlas.png
}
check source_protects_atlas
git checkout -q -- Assets/Art/atlas.png Assets/Art/Props/source.png

# Area-only generation must protect its prefab even with a trailing slash in areasDir.
area_keep() {
  cleanup_unity() { :; }
  unity() { printf 'regenerated\n' > "$PROJECT/Assets/Art/Areas/X.prefab"; }
  revert_bake_noise() { :; }
  cmd_scene --area X && grep -qx regenerated Assets/Art/Areas/X.prefab
}
# Scope function overrides to a subshell.
if (area_keep); then echo 'PASS: area_keep'; else echo 'FAIL: area_keep' >&2; failures=$((failures + 1)); fi

# Standalone recovery from a subdirectory honors both config and CLI protections.
for f in Kept/protected cli noise; do
  printf '  m_Floats:\n  - _ZTest: 4\n' > "Assets/Art/$f.mat"
done
standalone_keeps() {
  (cd Assets && bash "$tool_dir/scene-noise.sh" --keep Art/cli.mat) &&
    grep -q _ZTest Assets/Art/Kept/protected.mat &&
    grep -q _ZTest Assets/Art/cli.mat &&
    ! grep -q _ZTest Assets/Art/noise.mat
}
check standalone_keeps

# Different checkouts/installations still share udsMem*: hold the same cleanup
# lock across each editor run and its cleanup. A second run must fail safely.
serialization() {
  declare -F lock_unity >/dev/null || return 1
  (
    unset UNITY_CLEANUP_FD
    lock_unity
    printf 'owned\n' > "$SHM_DIR/udsMem-fixture"
    cp /usr/bin/sleep "$UNITY_ROOT/Editor/Unity"
    "$UNITY_ROOT/Editor/Unity" 60 &
    editor=$!
    export SHIP_FIXTURE_PIDS="$editor"
    trap 'kill "$editor" 2>/dev/null || true; wait "$editor" 2>/dev/null || true' EXIT
    (
      eval "exec ${UNITY_CLEANUP_FD}>&-"
      unset UNITY_CLEANUP_FD
      PROJECT="$tmp/other-project"
      mkdir -p "$PROJECT/Temp"
      lock_unity
      touch "$tmp/entered"
      cleanup_unity
    ) &
    contender=$!
    if wait "$contender"; then exit 1; fi
    kill -0 "$editor" && [ -f "$SHM_DIR/udsMem-fixture" ] && [ ! -f "$tmp/entered" ] || exit 1
    kill "$editor"; wait "$editor" 2>/dev/null || true
    cleanup_unity
    [ ! -f "$SHM_DIR/udsMem-fixture" ] || exit 1
    eval "exec ${UNITY_CLEANUP_FD}>&-"
    unset UNITY_CLEANUP_FD
    (lock_unity; touch "$tmp/reacquired")
    [ -f "$tmp/reacquired" ]
  )
}
check serialization
[ "$failures" = 0 ]
