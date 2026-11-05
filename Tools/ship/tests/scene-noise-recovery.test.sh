#!/usr/bin/env bash
# #259: a successful fake scene build leaves a git lock through cleanup, then the printed standalone recovery
# must clean bake-only metas and editor noise without touching pre-run edits, --keep paths or real bake changes.
set -euo pipefail
. "$(dirname "$0")/lib/fixture.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
proj="$tmp/proj"; dir=Assets/Scenes/GeneratedScene
mkdir -p "$proj/$dir/Kept" "$proj/Assets/Art/World/Materials" "$proj/Tools" "$tmp/bin" "$tmp/shm" "$tmp/unity/Editor"
# Vendor this checkout's tools so the advertised relative recovery command is exercised as shipped.
ship_fixture "$proj"
ship="$proj/Tools/ship"
cd "$proj"
git init -q
meta() { printf 'TextureImporter:\n  lightmap: 0\n  platformSettings:\n  - buildTarget: DefaultTexturePlatform\n  spriteSheet:\n    sprites: []\n  userData: \n'; }
for name in Clean Dirty Staged Kept Real; do meta > "$dir/Lightmap-$name.exr.meta"; done
meta > "$dir/Kept/Lightmap-Nested.exr.meta"
printf 'Material:\n  m_Floats: []\n' > Assets/Art/World/Materials/Clean.mat
printf 'scene\n' > Assets/Scenes/GeneratedScene.unity
printf 'LightingSettings:\n  m_BounceScale: 1\n' > "$dir/GeneratedSceneLighting.lighting"
git add Assets && git -c user.name=t -c user.email=t@t commit -qm base

# Fake editor writes only fixture assets. The lock is created after the last successful build step, so every
# cleanup retry sees it; the test removes only this fixture's lock after checking the failed-cleanup result.
cat > "$tmp/unity/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
set -eu
while [ $# -gt 0 ]; do
  case "$1" in -projectPath) p="$2"; shift ;; -executeMethod) m="$2"; shift ;; -logFile) l="$2"; shift ;; esac; shift
done
echo "ran $m" > "$l"
if [ "$m" = ExampleGame.World.Editor.WorldSceneBuilder.Run ]; then
  d="$p/Assets/Scenes/GeneratedScene"
  for f in "$d"/Lightmap-*.exr.meta "$d"/Kept/Lightmap-*.exr.meta; do
    sed -i '/^  - buildTarget: DefaultTexturePlatform/a\  - buildTarget: Standalone' "$f"
  done
  sed -i 's/lightmap: 0/lightmap: 1/' "$d/Lightmap-Real.exr.meta"
  echo rebuilt > "$p/Assets/Scenes/GeneratedScene.unity"
  sed -i 's/m_BounceScale: 1/m_BounceScale: 2/' "$d/GeneratedSceneLighting.lighting"
  printf 'Material:\n  m_Floats:\n  - _ZTest: 4\n' > "$p/Assets/Art/World/Materials/Clean.mat"
fi
if [ "$m" = ExampleGame.World.Editor.WorldStats.Run ]; then
  : > "$p/.git/index.lock"
fi
EOF
printf '#!/usr/bin/env bash\n[ "$1" = -a ] && shift\n[ "$1" = -s ] && shift 2\nexec "$@"\n' > "$tmp/bin/xvfb-run"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/nohup"
chmod +x "$tmp/unity/Editor/Unity" "$tmp/bin/"*
printf '<root><License id="Terms"><StopDate Value="" /></License><Signature>x</Signature></root>\n' > "$tmp/ulf"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT
export PATH="$tmp/bin:$PATH" UNITY_USERNAME=u UNITY_PASSWORD=p NOISE_BASE=HEAD
export PROJECT="$proj" OUT_DIR="$tmp/out" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" SHM_DIR="$tmp/shm"
export NOISE_GIT_TRIES=2 NOISE_GIT_DELAY=0 TASK_CACHE=no-task-cache
clean() { git diff --quiet HEAD -- "$1" && git diff --cached --quiet HEAD -- "$1"; }

# One unstaged pre-run edit is entirely inside platformSettings (otherwise the classifier alone would protect it).
sed -i 's/DefaultTexturePlatform/DefaultTexturePlatform # mine/' "$dir/Lightmap-Dirty.exr.meta"
# A staged edit whose working copy matches HEAD must also be protected: checkout would restore the staged change.
sed -i 's/DefaultTexturePlatform/DefaultTexturePlatform # staged/' "$dir/Lightmap-Staged.exr.meta"
git add "$dir/Lightmap-Staged.exr.meta"
git show "HEAD:$dir/Lightmap-Staged.exr.meta" > "$dir/Lightmap-Staged.exr.meta"
rc=0
(cd "$proj/$dir" && bash "$ship/linux-unity.sh" scene --keep ./Lightmap-Kept.exr.meta --keep ./Kept/) 2> "$tmp/build.err" || rc=$?
check 'successful scene with an exhausted lock exits 3' '[ "$rc" = 3 ] && grep -q "scene rebuilt" "$tmp/build.err" && grep -q "noise revert failed (git lock)" "$tmp/build.err"'
check 'cleanup leaves the lock in place and bake/editor noise pending' \
  '[ -f .git/index.lock ] && ! clean "$dir/Lightmap-Clean.exr.meta" && ! clean Assets/Art/World/Materials/Clean.mat'
check 'recovery saves pre-run lightmap edits' \
  'grep -qxF "$dir/Lightmap-Dirty.exr.meta" "$OUT_DIR/noise-before.txt" && grep -qxF "$dir/Lightmap-Staged.exr.meta" "$OUT_DIR/noise-before.txt"'

# Preserve exact contents (including staged state) of every protected output before invoking recovery.
protected=("$dir/Lightmap-Dirty.exr.meta" "$dir/Lightmap-Staged.exr.meta" "$dir/Lightmap-Kept.exr.meta"
  "$dir/Kept/Lightmap-Nested.exr.meta" "$dir/Lightmap-Real.exr.meta" "$dir/GeneratedSceneLighting.lighting" Assets/Scenes/GeneratedScene.unity)
git diff --binary HEAD -- "${protected[@]}" > "$tmp/protected.diff"
git diff --cached --binary HEAD -- > "$tmp/index.diff"
# Execute exactly the advertised shell-escaped command, with only this fixture's lock cleared.
recovery="$(sed -n 's/.*by hand (from .*): //p' "$tmp/build.err")"
check 'a standalone recovery command is advertised' '[[ "$recovery" == Tools/ship/scene-noise.sh* ]]'
rc=0; eval "$recovery" > "$tmp/locked-recovery.out" 2>&1 || rc=$?
check 'standalone recovery reports an exhausted lock without removing it' \
  '[ "$rc" = 75 ] && [ -f .git/index.lock ] && ! clean "$dir/Lightmap-Clean.exr.meta"'
rm .git/index.lock
# A rebuild can create an additional lightmap. Stage it only after the failed run,
# so it has no HEAD version and is not covered by the pre-run snapshot. Its name
# sorts before Clean, proving recovery continues to later bake-only candidates.
new_meta="$dir/Lightmap-Added.exr.meta"
meta > "$new_meta"
git add "$new_meta"
protected+=("$new_meta")
git diff --binary HEAD -- "${protected[@]}" > "$tmp/protected.diff"
git diff --cached --binary HEAD -- > "$tmp/index.diff"
rc=0; eval "$recovery" > "$tmp/recovery.out" 2>&1 || rc=$?
check 'standalone recovery succeeds after the lock clears' '[ "$rc" = 0 ]'
check 'standalone recovery keeps a staged new lightmap meta' \
  '[ -f "$new_meta" ] && git diff --cached --name-only -- "$new_meta" | grep -qxF "$new_meta"'
check 'standalone recovery cleans bake-only lightmap meta noise' 'clean "$dir/Lightmap-Clean.exr.meta"'
check 'standalone recovery also cleans editor noise' 'clean Assets/Art/World/Materials/Clean.mat'
git diff --binary HEAD -- "${protected[@]}" > "$tmp/after.diff"
git diff --cached --binary HEAD -- > "$tmp/after-index.diff"
check 'pre-run edits, keep file/directory, real meta/lighting/scene changes survive byte-for-byte' \
  'cmp -s "$tmp/protected.diff" "$tmp/after.diff" && cmp -s "$tmp/index.diff" "$tmp/after-index.diff"'

# Recovery is repeatable; --run must not opt open/test recovery into scene bake cleanup.
rc=0; eval "$recovery" > "$tmp/recovery.out" 2>&1 || rc=$?
check 'scene recovery is idempotent' '[ "$rc" = 0 ] && clean "$dir/Lightmap-Clean.exr.meta"'
sed -i '/^  - buildTarget: DefaultTexturePlatform/a\  - buildTarget: Standalone' "$dir/Lightmap-Clean.exr.meta"
bash "$ship/scene-noise.sh" --run > "$tmp/run.out" 2>&1
check 'open/test --run recovery does not clean scene bake changes' '! clean "$dir/Lightmap-Clean.exr.meta"'

# Distinguish absence from real Git failures: neither a failed tree lookup nor a
# failed blob read may be silently treated as a newly generated meta.
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "${FAIL_GIT_COMMAND:-}" ]; then
  echo 'injected Git object read failure' >&2
  exit 42
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$tmp/bin/git"
export REAL_GIT="$real_git"
for fail_command in ls-tree show; do
  rc=0
  REAL_GIT="$real_git" FAIL_GIT_COMMAND="$fail_command" bash "$ship/scene-noise.sh" \
    --before "$OUT_DIR/noise-before.txt" > "$tmp/git-failure.out" 2>&1 || rc=$?
  check "standalone recovery reports a genuine git $fail_command failure" \
    '[ "$rc" != 0 ] && grep -q "injected Git object read failure" "$tmp/git-failure.out" && ! clean "$dir/Lightmap-Clean.exr.meta"'
done

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
