#!/usr/bin/env bash
# Synthetic scene regressions with an isolated editor and project.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-scene-fixture.sh"

scene_outside_fixture
scene_props_fixture
# scene --area <Area>: PropSetup then BuildAreaFromCommandLine with -area <Area> (no full build, bake or stats).
git -C "$proj" checkout -q -- .
sed -i 's|^echo "ran \$m" > "\$l"$|echo "ran $m $*" >> "$p/../calls"\n&|' "$tmp/unity/Editor/Unity"
sed -i 's|^while \[ \$# -gt 0 \]; do$|all="$*"\n&|; s|echo "ran \$m \$\*"|echo "ran $m $all"|' "$tmp/unity/Editor/Unity"
rm -f "$tmp/calls"
(cd "$proj" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --area Area2 --area north-yard --area south_yard) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --area runs PropSetup then BuildAreaFromCommandLine with each -area" \
  'grep -q "PropSetup.Run" "$tmp/calls" && grep -q "BuildAreaFromCommandLine.*-area Area2 -area north-yard -area south_yard" "$tmp/calls"'
check "scene --area skips the full build and stats" '! grep -q "WorldSceneBuilder.Run\|WorldStats.Run" "$tmp/calls"'
rm -f "$tmp/calls"
for area in '../x' 'nested/area' 'nested\area' ''; do
  rc=0; (cd "$proj" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
    bash "$script" scene --area "$area") 2>"$tmp/err" || rc=$?
  check "scene --area rejects '$area' before running the editor" \
    '[ "$rc" = 1 ] && grep -Fq "is not an area name" "$tmp/err" && [ ! -e "$tmp/calls" ]'
done

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
