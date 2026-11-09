#!/usr/bin/env bash
# External Unity CLI profile build, arguments, artifact and failure propagation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

# Recreate the no-scene consumer state independently of the release-route test.
ship_fixture "$proj" no-scene
config_no_scene_files
jq '.unityVersion = "6000.7.1f1"' "$proj/yetikit.json" > "$tmp/changed.json"
mv "$tmp/changed.json" "$proj/yetikit.json"
mkdir -p "$UNITY_ROOT/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" \
  "$UNITY_ROOT/Editor/Data/PlaybackEngines/AndroidPlayer/NDK"
export APK_SWAP_GB=0 APK_MIN_FREE_GB=0 APK_MIN_FREE_GB_WARM=0

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
config_finish
