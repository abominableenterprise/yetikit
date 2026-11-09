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
  bash "$script" scene --area Court --area Pigeons) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --area runs PropSetup then BuildAreaFromCommandLine with each -area" \
  'grep -q "PropSetup.Run" "$tmp/calls" && grep -q "BuildAreaFromCommandLine.*-area Court -area Pigeons" "$tmp/calls"'
check "scene --area skips the full build and stats" '! grep -q "WorldSceneBuilder.Run\|WorldStats.Run" "$tmp/calls"'
rc=0; (cd "$proj" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --area '../x') 2>/dev/null || rc=$?
check "scene --area rejects a non-name" '[ "$rc" != 0 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
