#!/usr/bin/env bash
# Tests Tools/ship/scene-noise.sh (the editor-noise revert after `linux-unity.sh scene`) against a temp git project.
# Run: bash Tools/ship/tests/scene-noise.test.sh
set -euo pipefail
lib="$(cd "$(dirname "$0")/.." && pwd)/scene-noise.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
# Do not pipe echo into grep -q under pipefail: an early match can close the
# pipe before echo finishes, turning a successful assertion into SIGPIPE (141).
output_has() { grep -q -- "$1" <<< "$out"; }
clean() { git diff --quiet HEAD -- "$1"; }
# The temp repo has no origin/main: HEAD is the base unless a case sets NOISE_BASE itself.
export NOISE_BASE=HEAD

proj="$tmp/proj"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
cd "$proj"
git init -q
. "$proj/Tools/ship/lib/config.sh"
ship_config_load
mat() { printf 'Material:\n  m_SavedProperties:\n    m_Floats:\n    - _Cull: 2\n%s    m_Colors: []\n' "$1"; }
mkdir -p Assets/Art/World/Materials Assets/Art/Props/Soda Assets/Art/Props/Cup Assets/Scenes docs/art/world Assets/Editor/World
for m in Bench Fence Kept Edited Changed Removed; do mat "" > "Assets/Art/World/Materials/$m.mat"; done
mat "    - _ZTest: 4
" > Assets/Art/World/Materials/Removed.mat
echo png > Assets/Art/Props/Grabbables_Atlas.png
for p in Soda Cup; do
  echo mesh > "Assets/Art/Props/$p/${p}_Atlas.asset"; echo prefab > "Assets/Art/Props/$p/$p.prefab"
  echo fbx > "Assets/Art/Props/$p/$p.fbx"; echo jpg > "Assets/Art/Props/$p/${p}_BaseColor.jpg"
done
echo scene > Assets/Scenes/GeneratedScene.unity; echo stats > docs/art/world/stats.md
echo code > Assets/Editor/World/GrabCatalog.cs
git add -A && git -c user.name=t -c user.email=t@t commit -qm base

# Dirty before the build: Edited.mat.
sed -i 's/_Cull: 2/_Cull: 0/' Assets/Art/World/Materials/Edited.mat
. "$lib"
before="$(noise_dirty_files)"

# The "build": _ZTest noise on four materials, a real change on one, a removed _ZTest, atlas/meshes/prefabs re-packed,
# the scene and stats regenerated.
for m in Bench Fence Kept Edited; do sed -i 's/^    - _Cull: .*$/&\n    - _ZTest: 4/' "Assets/Art/World/Materials/$m.mat"; done
sed -i 's/^    - _Cull: .*$/&\n    - _ZTest: 4\n    - _Smoothness: 0.5/' Assets/Art/World/Materials/Changed.mat
sed -i '/_ZTest/d' Assets/Art/World/Materials/Removed.mat
echo png2 > Assets/Art/Props/Grabbables_Atlas.png
for p in Soda Cup; do echo mesh2 > "Assets/Art/Props/$p/${p}_Atlas.asset"; echo prefab2 > "Assets/Art/Props/$p/$p.prefab"; done
sed -i 's/^    - _Cull: .*$/&\n    - _ZTest: 4/' Assets/Art/World/Materials/Bench.mat
echo scene2 > Assets/Scenes/GeneratedScene.unity; echo stats2 > docs/art/world/stats.md

out="$(revert_editor_noise "$before" Assets/Art/World/Materials/Kept.mat 2>&1)"
echo "$out" | sed 's/^/     | /'
check "a .mat with only _ZTest lines is reverted" 'clean Assets/Art/World/Materials/Fence.mat && clean Assets/Art/World/Materials/Bench.mat'
check "a --keep file is kept" '! clean Assets/Art/World/Materials/Kept.mat && output_has "keeping Assets/Art/World/Materials/Kept.mat (--keep)"'
check "a file dirty before the build is kept" 'grep -q "_Cull: 0" Assets/Art/World/Materials/Edited.mat && grep -q _ZTest Assets/Art/World/Materials/Edited.mat'
check "a .mat with a real change besides _ZTest is kept" '! clean Assets/Art/World/Materials/Changed.mat'
check "a removed _ZTest is kept" '! clean Assets/Art/World/Materials/Removed.mat'
check "the atlas is reverted when no prop source changed" 'clean Assets/Art/Props/Grabbables_Atlas.png'
check "atlas meshes and prefabs are reverted when no prop source changed" \
  'clean Assets/Art/Props/Soda/Soda_Atlas.asset && clean Assets/Art/Props/Cup/Cup.prefab'
check "the scene and stats are never touched" '! clean Assets/Scenes/GeneratedScene.unity && ! clean docs/art/world/stats.md'
check "every revert is printed" 'output_has "reverting Assets/Art/Props/Grabbables_Atlas.png"'
# Force a multi-write producer: the assertion must also work when the matching
# line precedes more than a pipe buffer of diagnostics, regardless of scheduling.
out+="$(printf '%131072s' '')"
check "log assertions survive large output under pipefail" 'output_has "reverting Assets/Art/Props/Grabbables_Atlas.png"'

# A changed prop texture (or generator code): the atlas, meshes and prefabs are real output and are kept.
git checkout -q -- .
before="$(noise_dirty_files)"
echo jpg2 > Assets/Art/Props/Soda/Soda_BaseColor.jpg
git -c user.name=t -c user.email=t@t commit -qam "new soda texture"
echo png2 > Assets/Art/Props/Grabbables_Atlas.png
echo mesh2 > Assets/Art/Props/Cup/Cup_Atlas.asset; echo prefab2 > Assets/Art/Props/Cup/Cup.prefab
NOISE_BASE=HEAD~1 revert_editor_noise "$before" 2>/dev/null
check "a prop texture changed on the branch keeps the atlas and every re-packed prop" \
  '! clean Assets/Art/Props/Grabbables_Atlas.png && ! clean Assets/Art/Props/Cup/Cup_Atlas.asset && ! clean Assets/Art/Props/Cup/Cup.prefab'

git checkout -q -- .
before="$(noise_dirty_files)"
echo new > Assets/Art/Props/Cup/Cup.glb
echo png3 > Assets/Art/Props/Grabbables_Atlas.png
revert_editor_noise "$before" 2>/dev/null
check "an untracked prop GLB keeps the atlas" '! clean Assets/Art/Props/Grabbables_Atlas.png'
rm Assets/Art/Props/Cup/Cup.glb

git checkout -q -- .
echo code2 > Assets/Editor/World/GrabCatalog.cs
before="$(noise_dirty_files)"
echo png4 > Assets/Art/Props/Grabbables_Atlas.png
revert_editor_noise "$before" 2>/dev/null
check "a generator change keeps the atlas" '! clean Assets/Art/Props/Grabbables_Atlas.png'

git checkout -q -- .
echo png5 > Assets/Art/Props/Grabbables_Atlas.png
before=""
revert_editor_noise "$before" Assets/Art/Props/ 2>/dev/null
check "a --keep directory protects what is under it" '! clean Assets/Art/Props/Grabbables_Atlas.png'

# Code changes (Assets/Scripts/**, Assets/Editor/**, any .cs) keep every regenerated prefab and atlas mesh: the generator's
# inputs are not tracked one by one. The atlas PNG (textures only) and _ZTest-only materials are still reverted.
mkdir -p Assets/Scripts/Props
echo code > Assets/Scripts/Props/PropThrow.cs; echo code > Assets/Editor/World/PropCatalog.cs
git add -A && git -c user.name=t -c user.email=t@t commit -qm code
for code in Assets/Editor/World/PropCatalog.cs Assets/Scripts/Props/PropThrow.cs; do
  for committed in 0 1; do
    git checkout -q -- .
    echo changed >> "$code"
    [ "$committed" = 1 ] && git -c user.name=t -c user.email=t@t commit -qam "tune ${code##*/}"
    before="$(noise_dirty_files)"
    echo png6 > Assets/Art/Props/Grabbables_Atlas.png
    echo mesh6 > Assets/Art/Props/Cup/Cup_Atlas.asset; echo prefab6 > Assets/Art/Props/Soda/Soda.prefab
    sed -i 's/^    - _Cull: .*$/&\n    - _ZTest: 4/' Assets/Art/World/Materials/Fence.mat
    out="$(NOISE_BASE=HEAD~$committed revert_editor_noise "$before" 2>&1)"
    check "a ${code##*/} change (committed=$committed) keeps the prefabs and atlas meshes" \
      '! clean Assets/Art/Props/Soda/Soda.prefab && ! clean Assets/Art/Props/Cup/Cup_Atlas.asset && output_has "keeping Assets/Art/Props/Soda/Soda.prefab (code changed)"'
    check "a ${code##*/} change (committed=$committed) still reverts the atlas PNG and _ZTest noise" \
      'clean Assets/Art/Props/Grabbables_Atlas.png && clean Assets/Art/World/Materials/Fence.mat'
  done
done
git checkout -q -- .

# --keep spellings, resolved from the caller's directory (standalone run: no "before" list, so only --keep protects).
dirty() { echo prefab7 > Assets/Art/Props/Cup/Cup.prefab; echo prefab7 > Assets/Art/Props/Soda/Soda.prefab; }
keep_case() { # $1: name, $2: directory to run from, rest: --keep args. Cup.prefab must survive, Soda.prefab must not.
  local name="$1" from="$2"; shift 2
  git checkout -q -- .; dirty
  (cd "$from" && bash "$lib" "$@") > "$tmp/keep.out" 2>&1 || { cat "$tmp/keep.out"; }
  check "--keep $name protects Cup.prefab" '! clean Assets/Art/Props/Cup/Cup.prefab && clean Assets/Art/Props/Soda/Soda.prefab'
}
keep_case "repo-relative" "$proj" --keep Assets/Art/Props/Cup/Cup.prefab
keep_case "./x" "$proj" --keep ./Assets/Art/Props/Cup/Cup.prefab
keep_case "absolute" "$proj/Assets/Scenes" --keep "$proj/Assets/Art/Props/Cup/Cup.prefab"
keep_case "subdir-relative" "$proj/Assets/Art/Props" --keep Cup/Cup.prefab
keep_case "subdir ./x" "$proj/Assets/Art" --keep ./Props/Cup/Cup.prefab
keep_case "../ from a sibling" "$proj/Assets/Art/Props/Soda" --keep ../Cup/Cup.prefab
keep_case "directory, repo-relative" "$proj" --keep Assets/Art/Props/Cup
keep_case "directory, ./x/" "$proj" --keep ./Assets/Art/Props/Cup/
keep_case "directory, absolute" "$proj/docs" --keep "$proj/Assets/Art/Props/Cup"
keep_case "directory, ." "$proj/Assets/Art/Props/Cup" --keep .
keep_case "directory, subdir-relative" "$proj/Assets/Art" --keep Props/Cup
git checkout -q -- .; dirty
(cd "$proj" && bash "$lib" --keep .) >/dev/null 2>&1
check "--keep . at the root protects everything" '! clean Assets/Art/Props/Cup/Cup.prefab && ! clean Assets/Art/Props/Soda/Soda.prefab'
git checkout -q -- .; dirty
rc=0; (cd "$proj" && bash "$lib" --keep "$tmp/elsewhere/Cup.prefab") >/dev/null 2>&1 || rc=$?
check "a --keep outside the repository is an error and reverts nothing" \
  '[ "$rc" = 2 ] && ! clean Assets/Art/Props/Cup/Cup.prefab && ! clean Assets/Art/Props/Soda/Soda.prefab'
check "noise_keep_path resolves a not-yet-existing path" \
  '[ "$(cd "$proj/Assets/Art" && noise_keep_path "$proj" ./Props/New/New.prefab)" = Assets/Art/Props/New/New.prefab ]'
git checkout -q -- .

# #120: no usable merge-base with $NOISE_BASE (no such ref, unrelated history) means the branch's committed changes are
# unknown: keep the atlas, atlas meshes and prefabs with a diagnostic. Source-independent _ZTest noise is still reverted.
for nobase in origin/no-such-branch orphan; do
  git checkout -q -- .
  base="$nobase"
  if [ "$nobase" = orphan ]; then
    branch="$(git symbolic-ref --short HEAD)"
    git checkout -q --orphan unrelated && git -c user.name=t -c user.email=t@t commit -qm unrelated
    git checkout -q "$branch" && base=unrelated
  fi
  before="$(noise_dirty_files)"
  echo png8 > Assets/Art/Props/Grabbables_Atlas.png
  echo mesh8 > Assets/Art/Props/Cup/Cup_Atlas.asset; echo prefab8 > Assets/Art/Props/Soda/Soda.prefab
  sed -i 's/^    - _Cull: .*$/&\n    - _ZTest: 4/' Assets/Art/World/Materials/Fence.mat
  out="$(NOISE_BASE="$base" revert_editor_noise "$before" 2>&1)"
  check "no merge-base ($nobase): the atlas, meshes and prefabs are kept" \
    '! clean Assets/Art/Props/Grabbables_Atlas.png && ! clean Assets/Art/Props/Cup/Cup_Atlas.asset && ! clean Assets/Art/Props/Soda/Soda.prefab'
  check "no merge-base ($nobase): a diagnostic names the base" \
    'output_has "warning: no merge-base with $base, branch changes unknown" && output_has "keeping Assets/Art/Props/Soda/Soda.prefab (no merge-base"'
  check "no merge-base ($nobase): _ZTest-only noise is still reverted" 'clean Assets/Art/World/Materials/Fence.mat'
done
git checkout -q -- .

# #120: bash older than 4 (stock macOS 3.2) stops with a clear message instead of misbehaving under set -u.
rc=0; (cd "$proj" && NOISE_BASH_MAJOR=3 bash "$lib") >/dev/null 2>"$tmp/old.err" || rc=$?
check "bash < 4 is refused with a clear message (standalone)" \
  '[ "$rc" = 2 ] && grep -q "needs bash >= 4" "$tmp/old.err" && grep -q "brew install bash" "$tmp/old.err"'
rc=0; (NOISE_BASH_MAJOR=3; . "$lib") 2>/dev/null || rc=$?
check "bash < 4 is refused when sourced too" '[ "$rc" = 2 ]'

# Regression: under pipefail (linux-unity.sh) a big real diff must not read as _ZTest-only. grep -q stopping early used
# to SIGPIPE the printf feeding it, and the pipeline's 141 counted as "only noise" (a re-packed mesh was reverted so).
git checkout -q -- .
head -c 3000000 /dev/zero | tr '\0' 'a' > Assets/Art/World/Materials/Big.mat
git add -A && git -c user.name=t -c user.email=t@t commit -qm big
{ head -c 3000000 /dev/zero | tr '\0' 'b'; echo; for i in $(seq 1 2000); do echo "  - _ZTest: $i"; done; } \
  > Assets/Art/World/Materials/Big.mat
check "a big real diff is not _ZTest-only under pipefail" '! (set -o pipefail; noise_only_ztest Assets/Art/World/Materials/Big.mat)'
git checkout -q -- .
for i in $(seq 1 3000); do echo "Assets/Art/Props/P$i/P$i.prefab"; done > "$tmp/many"
echo Assets/Art/Props/Cup/Cup.fbx >> "$tmp/many"
check "a changed source at the end of a long list is found under pipefail" \
  '(set -o pipefail; noise_sources_changed "$(cat "$tmp/many")")'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
