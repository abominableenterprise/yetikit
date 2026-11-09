#!/usr/bin/env bash
# Synthetic scene regressions with an isolated editor and project.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-scene-fixture.sh"

scene_outside_fixture
# scene --keep resolves the path from the caller's directory: PropSetup.Run re-packs two prop prefabs (no source
# changed, so both are noise); the one passed as ./Cup.prefab from its own directory survives.
git -C "$proj" checkout -q -- .
scene_props_fixture
(cd "$props/Cup" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --keep ./Cup.prefab) 2>"$tmp/err" || { cat "$tmp/err"; exit 1; }
check "scene --keep ./x from a subdirectory keeps that prefab" 'grep -q repacked "$props/Cup/Cup.prefab"'
check "scene reverts the other re-packed prefab" 'git -C "$proj" diff --quiet -- "$props/Soda/Soda.prefab"'
rc=0; (cd "$tmp" && PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" \
  bash "$script" scene --keep ./nowhere) 2>/dev/null || rc=$?
check "scene --keep outside the project fails before building" '[ "$rc" != 0 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
