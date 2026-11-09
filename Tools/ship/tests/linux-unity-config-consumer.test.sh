#!/usr/bin/env bash
# Scene-free consumers, cache identity and executeMethod release artifact fallback.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

ship_fixture "$proj" no-scene
run scene
check 'scene-free consumer fails clearly before credentials or editor work' \
  '[ "$rc" != 0 ] && grep -q "no generated scene" "$tmp/err" && [ ! -e "$tmp/runs" ]'
rc=0
UNITY_USERNAME= UNITY_PASSWORD= bash "$script" scene >"$tmp/stdout" 2>"$tmp/err" || rc=$?
check 'no scene diagnostic does not depend on credentials' \
  '[ "$rc" != 0 ] && grep -q "no generated scene" "$tmp/err" && ! grep -q "set UNITY_USERNAME" "$tmp/err"'
config_no_scene_files
run cache-key
check 'minimal no-scene consumer supports cache commands' '[ "$rc" = 0 ] && [[ "$(< "$tmp/stdout")" =~ ^[0-9a-f]{64}$ ]]'
first="$(< "$tmp/stdout")"
jq '.unityVersion = "6000.7.1f1"' "$proj/yetikit.json" > "$tmp/changed.json"
mv "$tmp/changed.json" "$proj/yetikit.json"
run cache-key
check 'configured Unity version participates in cache identity' '[ "$rc" = 0 ] && [ "$(< "$tmp/stdout")" != "$first" ]'

# A release without releaseApkPath uses apkPath, not a kit-owned output name.
mkdir -p "$UNITY_ROOT/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" \
  "$UNITY_ROOT/Editor/Data/PlaybackEngines/AndroidPlayer/NDK"
export APK_SWAP_GB=0 APK_MIN_FREE_GB=0 APK_MIN_FREE_GB_WARM=0
export FAKE_MUTATE='mkdir -p Builds/Android; printf apk > Builds/Android/ExampleGame.apk'
run apk contest
check 'release falls back to configured apkPath' \
  '[ "$rc" = 0 ] && grep -q "GameBuild.ReleaseApk" "$tmp/runs" && grep -q "apk: $proj/Builds/Android/ExampleGame.apk" "$tmp/err"'
config_finish
