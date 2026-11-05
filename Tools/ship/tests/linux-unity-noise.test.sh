#!/usr/bin/env bash
# Tests the noise revert after `linux-unity.sh open` and `test`: tracked *.mat files whose diff only touches `_ZTest`
# lines and *.prefab files whose diff only re-formats floats (same numbers to 5 significant digits) are checked out;
# real changes, files dirty before the run and --keep paths are kept; a bare --keep skips the revert. Fake editor.
# Run: bash Tools/ship/tests/linux-unity-noise.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "$0")/lib/fake-unity.sh"

m="$proj/Assets/Art/Mats"; p="$proj/Assets/Prefabs"; mkdir -p "$m" "$p" "$proj/Library"
mat() { printf 'Material:\n  m_SavedProperties:\n    m_Floats:\n    - _Cull: 2\n    - _ZTest: %s\n    - _ZWrite: 1\n' "$1"; }
prefab() { printf 'Transform:\n  m_LocalPosition: {x: %s, y: 1.5, z: -0}\n  m_LocalScale: {x: 1, y: 1, z: 1}\n  m_Father: {fileID: %s}\n' "$1" "$2"; }
for n in Ztest Real Kept Dirty; do mat 4 > "$m/$n.mat"; done
for n in Floats Moved Ids Kept; do prefab 0.1 100 > "$p/$n.prefab"; done
printf 'Material:\n  m_Floats: []\n' > "$m/Empty.mat"
git_init

# The editor's noise: one _ZTest value per material, floats re-written per prefab; plus real changes.
FAKE_MUTATE='
for n in Ztest Kept Dirty; do sed -i "s/_ZTest: 4/_ZTest: 8/" "Assets/Art/Mats/$n.mat"; done
printf "Material:\n  m_Floats:\n  - _ZTest: 4\n" > Assets/Art/Mats/Empty.mat
sed -i "s/_Cull: 2/_Cull: 0/; s/_ZTest: 4/_ZTest: 8/" Assets/Art/Mats/Real.mat
for n in Floats Kept Dirty; do [ -f "Assets/Prefabs/$n.prefab" ] && sed -i "s/x: 0.1,/x: 0.100000001,/; s/z: -0}/z: 0}/; s/x: 1, y: 1/x: 1.0, y: 1e0/" "Assets/Prefabs/$n.prefab"; done
sed -i "s/x: 0.1,/x: 0.1001,/" Assets/Prefabs/Moved.prefab
sed -i "s/fileID: 100/fileID: 101/" Assets/Prefabs/Ids.prefab
'
export FAKE_MUTATE
reset() { git -C "$proj" checkout -q -- . && git -C "$proj" clean -qfd -e Library; }
clean() { git -C "$proj" diff --quiet -- "$1"; }
lu() { rc=0; bash "$script" "$@" 2>"$tmp/err" || rc=$?; }

# --- open ------------------------------------------------------------------------------------------------------------------
sed -i 's/_ZWrite: 1/_ZWrite: 0/' "$m/Dirty.mat"   # a developer edit before the run
lu open
check "open succeeds" '[ "$rc" = 0 ]'
check "open: a .mat whose diff only changes a _ZTest line is reverted and logged" \
  'clean Assets/Art/Mats/Ztest.mat && grep -q "reverting Assets/Art/Mats/Ztest.mat (only _ZTest lines)" "$tmp/err"'
check "open: a .mat gaining _ZTest (m_Floats: [] to a list) is reverted" 'clean Assets/Art/Mats/Empty.mat'
check "open: a .mat with a real change next to _ZTest is kept" '! clean Assets/Art/Mats/Real.mat && grep -q "keeping Assets/Art/Mats/Real.mat (a real change)" "$tmp/err"'
check "open: a .mat changed before the run is kept" '! clean Assets/Art/Mats/Dirty.mat && grep -q "keeping Assets/Art/Mats/Dirty.mat (changed before the run)" "$tmp/err"'
check "open: a .prefab with only float formatting changes (0.100000001, -0, 1.0, 1e0) is reverted and logged" \
  'clean Assets/Prefabs/Floats.prefab && grep -q "reverting Assets/Prefabs/Floats.prefab (only float formatting)" "$tmp/err"'
check "open: a .prefab with a number changed at 5 significant digits is kept" '! clean Assets/Prefabs/Moved.prefab'
check "open: a .prefab with a changed integer (fileID) is kept" '! clean Assets/Prefabs/Ids.prefab'

# --- test, --keep -----------------------------------------------------------------------------------------------------------
reset
# --keep paths resolve from the caller's directory, as for scene: a repo-relative one from the root, an absolute one.
cd "$proj"
EDITMODE_GFX=0 lu test editmode --keep Assets/Art/Mats/Kept.mat --keep "$p/Kept.prefab"
cd - >/dev/null
check "test: the noise revert runs after the passes too" '[ "$rc" = 0 ] && clean Assets/Art/Mats/Ztest.mat && clean Assets/Prefabs/Floats.prefab'
check "test --keep <path>: those files are kept and logged" \
  '! clean Assets/Art/Mats/Kept.mat && ! clean Assets/Prefabs/Kept.prefab && grep -q "keeping Assets/Art/Mats/Kept.mat (--keep)" "$tmp/err"'
check "test: --keep is not passed to the editor" '! grep -q -- --keep "$tmp/runs"'
reset
lu open --keep
check "open --keep (bare): no revert at all" \
  '[ "$rc" = 0 ] && ! clean Assets/Art/Mats/Ztest.mat && ! clean Assets/Prefabs/Floats.prefab && grep -q "noise revert skipped" "$tmp/err"'
reset
EDITMODE_GFX=0 lu test editmode --keep -testFilter X.Y
check "test editmode --keep -testFilter X: no revert, the filter still reaches the editor" \
  '[ "$rc" = 0 ] && ! clean Assets/Art/Mats/Ztest.mat && grep -q -- "-testFilter X.Y" "$tmp/runs"'
reset
EDITMODE_GFX=0 FAKE_FAILS=X.Real.Fail lu test editmode
check "a failed test run still reverts the noise and keeps its failure" '[ "$rc" != 0 ] && clean Assets/Art/Mats/Ztest.mat'
reset
FAKE_UNITY_RC=1 lu open
check "a failed open still reverts the noise and fails" '[ "$rc" != 0 ] && clean Assets/Art/Mats/Ztest.mat && grep -q "failed to open" "$tmp/err"'
lu open --keep ../../outside
check "open --keep outside the project fails" '[ "$rc" != 0 ] && grep -q "is not inside" "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
