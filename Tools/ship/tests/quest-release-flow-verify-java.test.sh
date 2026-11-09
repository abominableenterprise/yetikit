#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build

reset_logs; run verify "$apk"
check "verify runs android-launcher.py on the APK, checks the cert and prints the APK sha256" \
  '[ "$rc" = 0 ] && grep -Fq "$QR_SHIP_DIR/android-launcher.py --config $YETIKIT_CONFIG $apk" "$tmp/py.log" && out_has "apk sha256: $(qr_sha256 "$apk")" && grep -q "cert:        ok" "$tmp/out"'
FAKE_CERT="AA:BB" run verify "$apk"
check "verify fails on another signer certificate" '[ "$rc" != 0 ] && grep -q "cert:        MISMATCH" "$tmp/out"'
FAKE_LAUNCHER_RC=1 run verify "$apk"
check "verify fails when android-launcher.py rejects the APK" '[ "$rc" != 0 ] && out_has "android-launcher.py rejected"'
# Stub the Hub editor layout: SDK is beside Unity.app, not inside it.
editor="$tmp/hub/6000.6.6f1"
mkdir -p "$editor/PlaybackEngines/AndroidPlayer/SDK" "$editor/Unity.app/Contents/MacOS"
( unset ANDROID_SDK_ROOT; UNITY_HUB_EDITORS="$tmp/hub"; QR_SHORT="$short"; qr_config; qr_android_sdk 2>/dev/null; echo "$ANDROID_SDK_ROOT" ) > "$tmp/sdk.txt"
check "an unset ANDROID_SDK_ROOT points at the Hub editor's installed SDK" \
  '[ "$(cat "$tmp/sdk.txt")" = "$editor/PlaybackEngines/AndroidPlayer/SDK" ] && [ -d "$(cat "$tmp/sdk.txt")" ]'
( ANDROID_SDK_ROOT="$tmp/sdk"; UNITY_HUB_EDITORS="$tmp/hub"; qr_config; qr_android_sdk; echo "$ANDROID_SDK_ROOT" ) > "$tmp/sdk-override.txt"
check "an explicit ANDROID_SDK_ROOT is preserved" '[ "$(cat "$tmp/sdk-override.txt")" = "$tmp/sdk" ]'

# A stale "skipped: verify failed" from an earlier `all` clears once verify passes.
qr_config; qr_load_state; qr_set install "skipped: verify failed"
reset_logs; run verify "$apk"
check "a passing verify replaces an earlier 'install: skipped: verify failed'" \
  '[ "$rc" = 0 ] && ! grep -q "verify failed" "$tmp/out" && grep -q "install:     not run yet (verify ok)" "$tmp/out"'

# --- Java: apksigner and keytool need it; macOS's /usr/bin/java is only a stub.
hub="$tmp/jdk-hub"; fake_jdk "$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK"; fake_jdk "$hub/6000.0.1f1/PlaybackEngines/AndroidPlayer/OpenJDK"
# shellcheck disable=SC2031 # each case sets JAVA_HOME and PATH in its own subshell
java_env() { ( unset JAVA_HOME; [ -z "${1:-}" ] || JAVA_HOME="$1"; UNITY_HUB_EDITORS="${2:-$hub}"; qr_config; qr_java_setup && echo "$JAVA_HOME|${PATH%%:*}" ) 2>"$tmp/err"; }
check "no JAVA_HOME: the project's editor OpenJDK (ProjectVersion.txt), its bin first on PATH, logged" \
  '[ "$(java_env)" = "$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK|$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ] && grep -q "java: JAVA_HOME=$hub/6000.6.6f1/.*Unity" "$tmp/err"'
check "a working JAVA_HOME is kept" '[ "$(java_env "$tmp/jdk")" = "$tmp/jdk|$tmp/jdk/bin" ]'
check "a broken JAVA_HOME falls back to Unity's OpenJDK" '[ "$(java_env "$tmp/nope")" = "$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK|$hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ]'
rm -rf "$hub/6000.6.6f1"
check "without the project's editor, any Hub editor's OpenJDK" '[ "$(java_env)" = "$hub/6000.0.1f1/PlaybackEngines/AndroidPlayer/OpenJDK|$hub/6000.0.1f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ]'
for cmd in all build verify; do
  reset_logs; rm -f "$tmp/git.log"; rc=0; ( unset JAVA_HOME; UNITY_HUB_EDITORS="$tmp/no-hub"; qr_main "$cmd" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  check "$cmd with no Java anywhere fails at once, naming it, before prepare, Unity or verify" \
    '[ "$rc" != 0 ] && out_has "no Java runtime" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/py.log" ] && [ ! -f "$tmp/git.log" ]'
done


qr_flow_finish
