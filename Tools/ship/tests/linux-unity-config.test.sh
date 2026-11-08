#!/usr/bin/env bash
# Consumer configuration and both build routes, using synthetic projects/clients.
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
proj="$tmp/project"; fails=0
. "$(dirname "$0")/lib/fake-unity.sh"
cp "$proj/yetikit.json" "$tmp/scene.json"
run() { rc=0; bash "$script" "$@" >"$tmp/stdout" 2>"$tmp/err" || rc=$?; }
invalid() {
  local expression="$1" key="$2"
  jq "$expression" "$tmp/scene.json" > "$proj/yetikit.json"
  run cache-key
  check "invalid config names $key before command work" \
    '[ "$rc" != 0 ] && grep -Fq "$key" "$tmp/err" && [ ! -f "$tmp/runs" ]'
  rc=0
  bash -c '. "$1"' _ "$script" 2>"$tmp/source-err" || rc=$?
  check "source harness also rejects $key" '[ "$rc" != 0 ] && grep -Fq "$key" "$tmp/source-err"'
}
for key in schema unityVersion build build.devMethod build.releaseMethod build.apkPath scene.steps scene.lightmapDir; do
  invalid "del(.$key)" "$key"
done
while IFS='|' read -r expression key; do
  invalid "$expression" "$key"
done <<'EOF'
.schema = 2|schema
.unityVersion = ""|unityVersion
.build = []|build
.build.devMethod = 7|build.devMethod
.build.releaseMethod = ""|build.releaseMethod
.build.apkPath = "../outside.apk"|build.apkPath
.build.releaseApkPath = "/outside.apk"|build.releaseApkPath
.knownFlakes = false|knownFlakes
.labMethod = []|labMethod
.scene = null|scene
.scene.steps = []|scene.steps
.scene.steps = [42]|scene.steps
.scene.lightmapDir = "../outside"|scene.lightmapDir
.scene.areaStep = ""|scene.areaStep
.scene.areaSteps = []|scene.areaSteps
.scene.keepPaths = ["../outside"]|scene.keepPaths
.scene.areasFile = "/outside"|scene.areasFile
.noise = []|noise
.noise.atlasPath = 42|noise
.noise.fontAssetPaths = null|noise.fontAssetPaths
.noise.fontAssetPaths = "Assets/Fonts/Static.asset"|noise.fontAssetPaths
.noise.fontAssetPaths = [42]|noise.fontAssetPaths
.noise.fontAssetPaths = [""]|noise.fontAssetPaths
.noise.fontAssetPaths = ["/outside.asset"]|noise.fontAssetPaths
.noise.fontAssetPaths = ["../outside.asset"]|noise.fontAssetPaths
.noise.fontAssetPaths = ["Assets/Fonts/line\nbreak.asset"]|noise.fontAssetPaths
.tests = []|tests
.tests.builderFixtures = []|tests.builderFixtures
.tests.builderFixtures = {"Assets/Editor/Builder.cs": [42]}|tests.builderFixtures
EOF
for key in root editModeRoot scriptsRoot editorRoot; do
  for value in '"/outside"' '"Assets/../outside"' '42' 'null' '""'; do
    invalid ".tests.$key = $value" "tests.$key"
  done
done
printf '{broken\n' > "$proj/yetikit.json"
run cache-key
check 'malformed JSON has a clear diagnostic' '[ "$rc" != 0 ] && grep -q "invalid JSON" "$tmp/err"'
printf '{}\n{}\n' > "$proj/yetikit.json"
run cache-key
check 'streamed JSON objects are rejected' '[ "$rc" != 0 ] && grep -q "one JSON object" "$tmp/err"'
: > "$proj/yetikit.json"
run cache-key
check 'empty config is rejected' '[ "$rc" != 0 ] && grep -q "one JSON object" "$tmp/err"'
rm "$proj/yetikit.json"
run cache-key
check 'missing root config names yetikit.json' '[ "$rc" != 0 ] && grep -q "missing config.*yetikit.json" "$tmp/err"'

ship_fixture "$proj" no-scene
run scene
check 'scene-free consumer fails clearly before credentials or editor work' \
  '[ "$rc" != 0 ] && grep -q "no generated scene" "$tmp/err" && [ ! -e "$tmp/runs" ]'
rc=0
UNITY_USERNAME= UNITY_PASSWORD= bash "$script" scene >"$tmp/stdout" 2>"$tmp/err" || rc=$?
check 'no scene diagnostic does not depend on credentials' \
  '[ "$rc" != 0 ] && grep -q "no generated scene" "$tmp/err" && ! grep -q "set UNITY_USERNAME" "$tmp/err"'
mkdir -p "$proj/Packages" "$proj/ProjectSettings" "$proj/Library"
printf '{}\n' > "$proj/Packages/manifest.json"
printf '{}\n' > "$proj/Packages/packages-lock.json"
printf 'm_EditorVersion: 6000.6.6f1\n' > "$proj/ProjectSettings/ProjectVersion.txt"
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

# The alternate consumer uses an external Unity CLI profile rather than executeMethod.
jq '.build = {profile:"AndroidProfile", cli:"fixture-unity-cli", apkPath:"Builds/Android/Profile.apk"}' \
  "$proj/yetikit.json" > "$tmp/profile.json"
mv "$tmp/profile.json" "$proj/yetikit.json"
cat > "$tmp/bin/fixture-unity-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_TMP/cli-args"
[ "${FAKE_CLI_RC:-0}" = 0 ] || exit "$FAKE_CLI_RC"
out='' log=''
while [ "$#" -gt 0 ]; do
  case "$1" in --output-path) out="$2"; shift ;; -l) log="$2"; shift ;; esac
  shift
done
mkdir -p "$(dirname "$out")" "$(dirname "$log")"
printf 'profile apk' > "$out"
printf 'fake profile build\n' > "$log"
EOF
chmod +x "$tmp/bin/fixture-unity-cli"
unset FAKE_MUTATE
run apk
check 'CLI profile build succeeds and reports configured artifact' \
  '[ "$rc" = 0 ] && grep -q "apk: $proj/Builds/Android/Profile.apk" "$tmp/err"'
check 'CLI profile receives project, profile, editor and output path' \
  'grep -qx build "$tmp/cli-args" && grep -qx "$proj" "$tmp/cli-args" && grep -qx AndroidProfile "$tmp/cli-args" && grep -qx "$UNITY_ROOT/Editor/Unity" "$tmp/cli-args" && grep -qx "$proj/Builds/Android/Profile.apk" "$tmp/cli-args"'
check 'CLI profile retains APK export, dirty-build, timeout and log flags' \
  'for flag in --android-export-type apk --allow-dirty-build --timeout --no-tail -l; do grep -qx -- "$flag" "$tmp/cli-args" || exit 1; done; grep -qx "$OUT_DIR/apk.log" "$tmp/cli-args"'
FAKE_CLI_RC=7 run apk
check 'CLI profile failure is propagated' '[ "$rc" != 0 ]'
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
