#!/usr/bin/env bash
# Sourced by quest-release.test.sh after the release-flow tests. Uses its fake
# editor/device harness and accumulated state; never invokes a real editor or adb.
# shellcheck disable=SC2016 # check conditions are expanded by the parent harness

# --- doctor: read-only, seconds; ok / warn / FAIL per item -------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/sdk/build-tools/30.0.3" "$tmp/sdk/build-tools/34.0.0"
cp "$(command -v bash)" "$tmp/bin/Unity" # a real program named Unity (also the fake rel-* editor below)
printf '#!/bin/sh\necho old >> "%s/apksigner-bin.log"\n' "$tmp" > "$tmp/sdk/build-tools/30.0.3/apksigner"
printf '#!/bin/sh\necho "$*" >> "%s/apksigner-bin.log"\n[ -z "$FAKE_APKSIGNER_STDOUT" ] || echo "$FAKE_APKSIGNER_STDOUT"\n[ -n "$FAKE_APKSIGNER_FAIL" ] && exit 1\necho 0.9\n' "$tmp" > "$tmp/sdk/build-tools/34.0.0/apksigner"
chmod +x "$tmp/sdk/build-tools/"*/apksigner
doctor_run() {
  reset_logs; rm -f "$tmp/git.log" "$tmp/apksigner-bin.log"
  find "$root" | sort > "$tmp/tree-before"
  rc=0; ( UNITY_BIN="$tmp/bin/Unity"; export UNITY_BIN; qr_main doctor ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  find "$root" | sort > "$tmp/tree-after"
}
line() { tr -s " " < "$tmp/out" | grep -q "^$1 $2"; } # the columns are padded
doctor_run
check "doctor all green with the fakes: one ok line per item, exit 0" \
  '[ "$rc" = 0 ] && for i in java apksigner keystore unity disk device idle running; do line ok "$i " || exit 1; done && ! grep -qE "^(FAIL|warn) " "$tmp/out" && grep -q "doctor: no FAIL" "$tmp/out"'
check "doctor names the JDK source, the newest build-tools apksigner, the keystore path, the editor and free GB" \
  'line ok "java .*JAVA_HOME=$tmp/jdk (JAVA_HOME)" && line ok "apksigner $tmp/sdk/build-tools/34.0.0/apksigner (0.9)" && [ "$(cat "$tmp/apksigner-bin.log")" = --version ] && line ok "keystore $HOME/.android/debug.keystore matches" && line ok "unity $tmp/bin/Unity" && line ok "disk 100 GB free" && line ok "idle idle (Home focused)"'
check "doctor is read-only: no Unity, no adb install / shell pm / am / logcat, no fetch, no worktree, run folder or lock" \
  '[ ! -f "$tmp/unity.log" ] && ! grep -qE " install | shell pm | shell am |logcat|exec-out" "$tmp/adb.log" && [ ! -f "$tmp/git.log" ] && cmp -s "$tmp/tree-before" "$tmp/tree-after" && ! grep -q "Quest release summary" "$tmp/out"'
rc=0; ( unset JAVA_HOME; UNITY_HUB_EDITORS="$tmp/no-hub"; doctor_run; exit "$rc" ) || rc=$?
check "doctor FAILs with no Java anywhere (and says why apksigner cannot run)" '[ "$rc" != 0 ] && line FAIL "java no runnable JDK" && line FAIL "apksigner .*needs Java" && grep -q "doctor: 2 FAIL" "$tmp/out"'
fake_jdk "$tmp/doc-hub/6000.6.6f1/PlaybackEngines/AndroidPlayer/OpenJDK"
rc=0; ( unset JAVA_HOME; UNITY_HUB_EDITORS="$tmp/doc-hub"; doctor_run; exit "$rc" ) || rc=$?
check "doctor says when the JDK is Unity's bundled OpenJDK" '[ "$rc" = 0 ] && line ok "java .*doc-hub/6000.6.6f1/.*(Unity.s bundled OpenJDK)"'
FAKE_APKSIGNER_FAIL=1 doctor_run
check "doctor FAILs when apksigner --version does not run with that JAVA_HOME" '[ "$rc" != 0 ] && line FAIL "apksigner .*--version does not run"'
FAKE_APKSIGNER_STDOUT='0.9 (diagnostic before failure)' FAKE_APKSIGNER_FAIL=1 doctor_run
check "doctor rejects apksigner stdout followed by a nonzero exit (without pipefail)" \
  '[ "$rc" != 0 ] && line FAIL "apksigner .*--version does not run" && ! line ok apksigner'
FAKE_APKSIGNER_STDOUT='first version line' doctor_run
check "doctor reports only the first line of successful apksigner output" \
  '[ "$rc" = 0 ] && line ok "apksigner .* (first version line)" && ! grep -q "^0.9" "$tmp/out"'
rc=0; ( ANDROID_SDK_ROOT="$tmp/no-sdk"; doctor_run; exit "$rc" ) || rc=$?
check "doctor FAILs with no apksigner in the SDK" '[ "$rc" != 0 ] && line FAIL "apksigner no apksigner"'
FAKE_STATE=unauthorized doctor_run
check "doctor FAILs when the Quest adb state is not device (and skips the idle check)" \
  '[ "$rc" != 0 ] && line FAIL "device .*adb state .unauthorized." && line warn "idle not checked" && ! grep -q dumpsys "$tmp/adb.log"'
FAKE_MAKER=samsung doctor_run
check "doctor FAILs on a non-Oculus device" '[ "$rc" != 0 ] && line FAIL "device .*not Oculus"'
rc=0
# Hide only adb discovery: jq and filesystem tools are needed by config loading.
( unset -f adb
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = adb ]; then return 1; fi; builtin command "$@"; }
  doctor_run; exit "$rc"
) 2>/dev/null || rc=$?
check "doctor FAILs with no adb on PATH" '[ "$rc" != 0 ] && line FAIL "device no adb on PATH"'
wrong="6F:0A:D4:16:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB"
FAKE_KEYSTORE_CERT="$wrong" doctor_run
check "doctor FAILs on a debug keystore with the wrong certificate, printing only 16 hex digits" \
  '[ "$rc" != 0 ] && line FAIL "keystore $HOME/.android/debug.keystore has certificate 6f0ad41600112233\.\.\., expected 0011223344556677" && ! grep -qi "6f0ad4160011223344\|PrivateKeyEntry\|SHA1" "$tmp/out" "$tmp/err"'
mkdir -p "$tmp/xdg/.android"; echo other-key > "$tmp/xdg/.android/debug.keystore"
rc=0; ( XDG_CONFIG_HOME="$tmp/xdg"; export XDG_CONFIG_HOME; FAKE_XDG_CERT="$wrong" doctor_run; exit "$rc" ) || rc=$?
check "doctor warns (only) when XDG_CONFIG_HOME/.android/debug.keystore has another certificate" \
  '[ "$rc" = 0 ] && line ok "keystore $HOME/.android/debug.keystore matches" && line warn "keystore XDG_CONFIG_HOME is set and $tmp/xdg/.android/debug.keystore has another certificate (6f0ad41600112233\.\.\.)" && ! grep -qi 6f0ad4160011223344 "$tmp/out"'
rc=0; ( XDG_CONFIG_HOME="$tmp/xdg"; export XDG_CONFIG_HOME; doctor_run; exit "$rc" ) || rc=$?
check "doctor stays quiet when the XDG keystore has the same certificate" '[ "$rc" = 0 ] && ! grep -q "^warn" "$tmp/out"'
FAKE_FREE_GB=12 doctor_run
check "doctor FAILs under QUEST_MIN_FREE_GB free" '[ "$rc" != 0 ] && line FAIL "disk only 12 GB free"'
rc=0; ( UNITY_HUB_EDITORS="$tmp/no-hub"; reset_logs; ( qr_main doctor ) > "$tmp/out" 2> "$tmp/err" ) || rc=$?
check "doctor FAILs when the configured project editor is missing" '[ "$rc" != 0 ] && line FAIL "unity no Unity editor at $tmp/no-hub/6000.6.6f1/"'
FAKE_FIXTURE=game-mounted doctor_run
check "doctor only warns when the headset is in use (it never installs)" '[ "$rc" = 0 ] && line warn "idle in use (worn (HEADSET_MOUNTED)"'
FAKE_FIXTURE=game-mounted FAKE_VR=0 FAKE_POWER_MODE=ambiguous doctor_run
check "doctor only warns when the idle state is unknown" '[ "$rc" = 0 ] && line warn "idle unknown (cannot tell"'
sleep 300 >/dev/null 2>&1 & live=$!
mkdir -p "$lock"; echo "$live" > "$lock/pid"; echo "$tmp/other-run" > "$lock/run_dir"
doctor_run
check "doctor FAILs while a live run holds the lock, naming its PID and run folder, and leaves the lock alone" \
  '[ "$rc" != 0 ] && line FAIL "running another quest-release run is active (pid $live, run folder $tmp/other-run)" && [ "$(cat "$lock/pid")" = "$live" ]'
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
doctor_run
check "doctor only warns about a stale lock and does not remove it" '[ "$rc" = 0 ] && line warn "running stale lock" && [ -d "$lock" ]'
rm -rf "$lock"
"$tmp/bin/Unity" -c 'trap "kill \$! 2>/dev/null; exit" TERM; sleep 300 & wait' -batchmode -projectPath "$root/rel-$short-test" -logFile "$tmp/edrun/gate-unity.log" >/dev/null 2>&1 & ed=$!
sleep 1
doctor_run
kill "$ed" 2>/dev/null; wait "$ed" 2>/dev/null
check "doctor FAILs while a Unity editor runs on a rel-* worktree, naming its PID and run folder" \
  '[ "$rc" != 0 ] && line FAIL "running a Unity editor is running on $root/rel-$short-test (pid $ed, run folder $tmp/edrun)"'
# ps flattens argv on both macOS and Linux: cover whitespace in executable, project and log paths without real Unity.
rc=0
(
  qr_config
  QR_ROOT="$tmp/work trees"
  ps() {
    case " $* " in *" -ww "*) ;; *) return 1 ;; esac
    printf '%s\n' \
      "  8101 /Applications/Unity Hub/Editor/Unity.app/Contents/MacOS/Unity -batchmode -projectPath $QR_ROOT/rel-abc-build -logFile $tmp/run logs/build-unity.log -quit" \
      "  8102 /Applications/Unity/Editor/Unity.app/Contents/MacOS/Unity -projectPath $QR_ROOT/rel-abc-test -quit" \
      "  8103 /Applications/Unity Hub/Unity -projectPath \"$QR_ROOT/rel-quoted-build\" -logFile \"$tmp/run logs/quoted.log\"" \
      "  8104 /Applications/Unity Hub/Unity -projectPath $QR_ROOT/mac-pass -quit" \
      "  8105 /Applications/Unity Hub/UnityHelper -projectPath $QR_ROOT/rel-abc-test" \
      "  8106 sh -c /Applications/Unity Hub/Unity -projectPath $QR_ROOT/rel-abc-test" \
      "  8107 /Applications/Unity Hub/Unity -projectPath $QR_ROOT-other/rel-abc-test"
  }
  qr_doctor_rel_editors
) > "$tmp/space-editors" || rc=$?
check "editor scan preserves whitespace in executable, release worktree and log paths" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/space-editors")" = 3 ] && grep -Fqx "$(printf "8101\t%s\t%s" "$tmp/work trees/rel-abc-build" "$tmp/run logs/build-unity.log")" "$tmp/space-editors" && grep -Fqx "$(printf "8102\t%s\t" "$tmp/work trees/rel-abc-test")" "$tmp/space-editors" && grep -Fqx "$(printf "8103\t%s\t%s" "$tmp/work trees/rel-quoted-build" "$tmp/run logs/quoted.log")" "$tmp/space-editors"'
# BSD ps without -ww cuts args to the terminal width (79 columns with none), dropping a Unity.app editor's -projectPath.
"$tmp/bin/Unity" -c 'trap "kill \$! 2>/dev/null; exit" TERM; sleep 300 & wait' -batchmode -force-metal -nographics -projectPath "$root/rel-$short-test" -logFile "$tmp/edrun/gate-unity.log" >/dev/null 2>&1 & ed=$!
sleep 1
ps() { case " $* " in *" -ww "*) command ps "$@" ;; *) command ps "$@" | cut -c1-79 ;; esac; }
doctor_run
unset -f ps
kill "$ed" 2>/dev/null; wait "$ed" 2>/dev/null
check "doctor finds a rel-* editor whose command line is wider than 79 columns (ps -ww)" \
  '[ "$rc" != 0 ] && line FAIL "running a Unity editor is running on $root/rel-$short-test (pid $ed"'
"$tmp/bin/Unity" -c 'trap "kill \$! 2>/dev/null; exit" TERM; sleep 300 & wait' -batchmode -projectPath "$root/mac-pass" -logFile "$tmp/x.log" >/dev/null 2>&1 & ed=$!
sleep 1
doctor_run
kill "$ed" 2>/dev/null; wait "$ed" 2>/dev/null
check "an editor on another worktree (mac-pass) is not a release run" '[ "$rc" = 0 ] && line ok running'

# Standard macOS Hub layout (flat editor layouts and explicit overrides are covered by the parent harness).
mac_hub="$tmp/mac hub"
mac_contents="$mac_hub/6000.6.6f1/Unity.app/Contents"
mkdir -p "$mac_contents/PlaybackEngines/AndroidPlayer/SDK/build-tools/34.0.0"
fake_jdk "$mac_contents/PlaybackEngines/AndroidPlayer/OpenJDK"
cp "$tmp/sdk/build-tools/34.0.0/apksigner" "$mac_contents/PlaybackEngines/AndroidPlayer/SDK/build-tools/34.0.0/apksigner"
rc=0
(
  unset ANDROID_SDK_ROOT JAVA_HOME
  UNITY_HUB_EDITORS="$mac_hub"
  qr_config
  qr_android_sdk && qr_java_setup || exit 1
  printf '%s\n' "$ANDROID_SDK_ROOT" "$JAVA_HOME" "${PATH%%:*}"
) > "$tmp/mac-tools" 2> "$tmp/err" || rc=$?
check "macOS Hub SDK and project JDK resolve beneath Unity.app/Contents, including spaces" \
  '[ "$rc" = 0 ] && [ "$(head -n1 "$tmp/mac-tools")" = "$mac_contents/PlaybackEngines/AndroidPlayer/SDK" ] && [ "$(tail -n2 "$tmp/mac-tools" | head -n1)" = "$mac_contents/PlaybackEngines/AndroidPlayer/OpenJDK" ] && [ "$(tail -n1 "$tmp/mac-tools")" = "$mac_contents/PlaybackEngines/AndroidPlayer/OpenJDK/bin" ]'
rc=0
(
  unset JAVA_HOME
  UNITY_HUB_EDITORS="$mac_hub"
  QR_REPO="$tmp/missing-project"
  qr_java_setup && printf '%s\n' "$JAVA_HOME"
) > "$tmp/mac-fallback" 2> "$tmp/err" || rc=$?
check "macOS Hub JDK fallback searches installed app bundles without a project editor" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/mac-fallback")" = "$mac_contents/PlaybackEngines/AndroidPlayer/OpenJDK" ]'
rc=0
(
  UNITY_HUB_EDITORS="$mac_hub"
  ANDROID_SDK_ROOT="$tmp/sdk"
  JAVA_HOME="$tmp/jdk"
  qr_config
  qr_android_sdk && qr_java_setup || exit 1
  [ "$ANDROID_SDK_ROOT" = "$tmp/sdk" ] && [ "$JAVA_HOME" = "$tmp/jdk" ]
) 2> "$tmp/err" || rc=$?
check "explicit SDK and working JAVA_HOME override the macOS bundles" '[ "$rc" = 0 ]'
# qr_main verify already sets up Java; exercise that entry point with only the embedded JDK and fake apksigner.
rc=0
(
  unset JAVA_HOME ANDROID_SDK_ROOT
  UNITY_HUB_EDITORS="$mac_hub"
  apksigner() {
    [ "$JAVA_HOME" = "$mac_contents/PlaybackEngines/AndroidPlayer/OpenJDK" ] || return 1
    [ "${PATH%%:*}" = "$JAVA_HOME/bin" ] || return 1
    local bin
    bin="$(qr_apksigner_path)" || return 1
    "$bin" --version || return 1
    printf 'Signer #1 certificate SHA-256 digest: %s\n' "$cert"
  }
  run verify "$apk"
  exit "$rc"
) || rc=$?
check "verify with only a macOS embedded JDK exports Java and finds bundled SDK apksigner" \
  '[ "$rc" = 0 ] && grep -q "verify: signer certificate ok" "$tmp/err" && [ ! -f "$tmp/unity.log" ]'
