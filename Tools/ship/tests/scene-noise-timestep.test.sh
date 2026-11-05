#!/usr/bin/env bash
# Fixed Timestep cleanup in scene and open/test paths, using only a temporary git repo (no Unity).
# Run: bash Tools/ship/tests/scene-noise-timestep.test.sh
set -euo pipefail
# SCENE_NOISE_LIB can point at a baseline copy for failing-first verification without editing the working source.
lib="${SCENE_NOISE_LIB:-$(cd "$(dirname "$0")/.." && pwd)/scene-noise.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
export NOISE_BASE=HEAD
proj="$tmp/proj"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
# Rational serialization is recognized only when the consumer explicitly configures its count.
jq '.noise.fixedTimestepCount = "1960000"' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
mkdir -p "$proj/ProjectSettings"
cd "$proj"
git init -q
. "$proj/Tools/ship/lib/config.sh"
ship_config_load
. "$lib"
f=ProjectSettings/TimeManager.asset
fixture() {
  printf '%%YAML 1.1\nTimeManager:\n  Fixed Timestep: %s\n  Maximum Allowed Timestep: %s\n  m_TimeScale: 1\n' "$1" "${2:-0.33333334}"
}
rational() {
  printf '%%YAML 1.1\nTimeManager:\n  Fixed Timestep:\n    m_Count: %s\n  Maximum Allowed Timestep: %s\n  m_TimeScale: 1\n' "${1:-1960000}" "${2:-0.33333334}"
}
fixture 0.013888889 > "$f"
fixture 0.013888889 > ProjectSettings/Other.asset
git add -A
git -c user.name=t -c user.email=t@t commit -qm base
clean() { git diff --quiet HEAD -- "$1"; }
reset() {
  git checkout -q -- .
  noise_dirty_files > "$tmp/before"
}
cleanup() { bash "$lib" "${mode[@]}" --before "$tmp/before" "$@" > "$tmp/out" 2>&1; }

for path in scene open/test; do
  mode=()
  [ "$path" = scene ] || mode=(--run)
  # No Assets/Art changes: the scene path must not return before checking TimeManager.
  for value in 0.01388888992369175 1.3888889e-2 0.013888980 0.013888790; do
    reset
    fixture "$value" > "$f"
    cleanup
    check "$path: formatting/delta <= 1e-7 ($value) is reverted" \
      'clean "$f" && grep -q "reverting $f (only Fixed Timestep formatting)" "$tmp/out"'
  done

  reset
  rational > "$f"
  cleanup
  check "$path: float to rational 1/72 serialization is reverted" 'clean "$f"'

  for count in 2822400 1960001 0 -1960000 1.96e6; do
    reset
    rational "$count" > "$f"
    cleanup
    check "$path: unrecognized rational count ($count) is kept" '! clean "$f"'
  done

  reset
  rational 1960000 0.33333335 > "$f"
  cleanup
  check "$path: rational conversion with another setting changed is kept" '! clean "$f"'

  for extra in '    m_Rate: 141120000' '    m_Count: 1960000' '  Fixed Timestep: 0.013888889'; do
    reset
    rational > "$f"
    printf '%s\n' "$extra" >> "$f"
    cleanup
    check "$path: rational conversion with extra/duplicate field ($extra) is kept" '! clean "$f"'
  done

  reset
  fixture 0.013888890 > "$f"
  noise_dirty_files > "$tmp/before"
  rational > "$f"
  cleanup
  check "$path: pre-dirty rational conversion is kept" '! clean "$f"'

  for keep in "$f" ProjectSettings; do
    reset
    rational > "$f"
    cleanup --keep "$keep"
    check "$path: --keep $keep protects rational conversion" '! clean "$f"'
  done

  reset
  rm "$f"
  cleanup
  check "$path: deleted timestep settings are kept deleted" '[ ! -e "$f" ]'

  for value in 0.02 0.013888990 0.013888788; do
    reset
    fixture "$value" > "$f"
    cleanup
    check "$path: real timestep change ($value) is kept" '! clean "$f"'
  done

  reset
  fixture 0.01388888992369175 0.33333335 > "$f"
  cleanup
  check "$path: other property formatting, even a tiny float change, is kept" '! clean "$f"'

  reset
  fixture 0.01388888992369175 > "$f"
  printf '  AddedProperty: 1\n' >> "$f"
  cleanup
  check "$path: an added property is kept" '! clean "$f"'

  reset
  fixture 0.01388888992369175 > "$f"
  noise_dirty_files > "$tmp/before"
  fixture 0.013888890 > "$f"
  cleanup
  check "$path: pre-dirty float-only timestep is kept" \
    '! clean "$f" && grep -q "keeping $f (changed before" "$tmp/out"'

  for keep in "$f" ProjectSettings; do
    reset
    fixture 0.01388888992369175 > "$f"
    cleanup --keep "$keep"
    check "$path: --keep $keep protects timestep formatting" \
      '! clean "$f" && grep -q "keeping $f (--keep)" "$tmp/out"'
  done

  # A staged setting can be invisible to a working-tree-vs-HEAD diff. Checkout without a
  # tree-ish would restore that staged value, not the HEAD baseline used to validate noise.
  reset
  fixture 0.02 > "$f"
  git add -- "$f"
  git show ":$f" > "$tmp/staged"
  git show "HEAD:$f" > "$f"
  check "$path: staged regression starts with worktree at HEAD and a dirty index" \
    'clean "$f" && ! git diff --cached --quiet HEAD -- "$f"'
  noise_dirty_files > "$tmp/before"
  check "$path: staged-but-restored timestep is recorded as pre-dirty" 'grep -qxF "$f" "$tmp/before"'
  fixture 0.01388888992369175 > "$f"
  cp "$f" "$tmp/expected"
  cleanup
  check "$path: cleanup preserves the working file instead of restoring the staged setting" \
    'cmp -s "$f" "$tmp/expected" && grep -q "keeping $f (changed before" "$tmp/out"'
  git show ":$f" > "$tmp/staged-after"
  check "$path: cleanup leaves the staged setting byte-identical" 'cmp -s "$tmp/staged" "$tmp/staged-after"'
  git reset -q HEAD -- "$f"

  reset
  fixture 0.01388888992369175 > ProjectSettings/Other.asset
  cleanup
  check "$path: another settings asset is never reverted" '! clean ProjectSettings/Other.asset'
done

# A branch may already have the rational serialization committed; handle equivalent float output too.
reset
rational > "$f"
git add -- "$f"
git -c user.name=t -c user.email=t@t commit -qm rational
for path in scene open/test; do
  mode=()
  [ "$path" = scene ] || mode=(--run)
  reset
  fixture 0.013888889 > "$f"
  cleanup
  check "$path: rational to equivalent float serialization is reverted" 'clean "$f"'
  reset
  rational 2822400 > "$f"
  cleanup
  check "$path: rational to a different rational timestep is kept" '! clean "$f"'
  reset
  fixture 0.02 > "$f"
  cleanup
  check "$path: rational to a different float timestep is kept" '! clean "$f"'
done

# The known rational count is not noise when the committed timestep was genuinely different.
reset
fixture 0.02 > "$f"
git add -- "$f"
git -c user.name=t -c user.email=t@t commit -qm different-timestep
for path in scene open/test; do
  mode=()
  [ "$path" = scene ] || mode=(--run)
  reset
  rational > "$f"
  cleanup
  check "$path: 1/50 float to 1/72 rational is a real edit and is kept" '! clean "$f"'
done

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
