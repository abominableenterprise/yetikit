#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_prepare

# --- the debug keystore Gradle signs with: ANDROID_USER_HOME, never $XDG_CONFIG_HOME/.android --------------------------------
export XDG_CONFIG_HOME="$HOME/.config" # what a fish login shell exports
reset_logs; run build
check "build: the editor sees ANDROID_USER_HOME=\$HOME/.android and no XDG_CONFIG_HOME the caller exported" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/unity-env.log")" = "ANDROID_USER_HOME=$HOME/.android XDG_CONFIG_HOME=unset" ]'
# shellcheck disable=SC2031 # qr_build sets ANDROID_USER_HOME only in its own subshell: that is the point
( qr_config; qr_load_state; qr_build >/dev/null 2>&1 && echo "${XDG_CONFIG_HOME-unset} ${ANDROID_USER_HOME-unset}" ) > "$tmp/caller-env.txt"
check "build leaves the caller's own environment alone" '[ "$(cat "$tmp/caller-env.txt")" = "$HOME/.config unset" ]'
unset XDG_CONFIG_HOME
# shellcheck disable=SC2031
export ANDROID_USER_HOME="$tmp/android-user"
reset_logs; run build
check "build respects a caller-set ANDROID_USER_HOME" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/unity-env.log")" = "ANDROID_USER_HOME=$tmp/android-user XDG_CONFIG_HOME=unset" ]'
unset ANDROID_USER_HOME
reset_logs; run build
check "no debug keystore yet: the preflight logs and the build runs" \
  '[ "$rc" = 0 ] && [ -f "$tmp/unity.log" ] && [ ! -f "$tmp/keytool.log" ] && out_has "no $HOME/.android/debug.keystore"'
mkdir -p "$HOME/.android"; echo not-a-real-keystore > "$HOME/.android/debug.keystore"
rc=0
# Hide keytool only after config has loaded, without hiding jq or filesystem tools.
( qr_config; unset -f keytool
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = keytool ]; then return 1; fi; builtin command "$@"; }
  qr_keystore_preflight
) > "$tmp/out" 2> "$tmp/err" || rc=$?
check "no keytool: the preflight logs and continues" '[ "$rc" = 0 ] && out_has "no keytool"'
reset_logs; FAKE_KEYSTORE_CERT="6F:0A:D4:16:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB" run build
check "a debug keystore with another certificate stops build before Unity runs, naming the keystore" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/unity.log" ] && out_has "$HOME/.android/debug.keystore" && out_has "6f0ad416" && grep -q "apk:         not built" "$tmp/out"'
check "the preflight reads the debug alias with an env password source and prints only the fingerprint" \
  'grep -q -- "-keystore $HOME/.android/debug.keystore -storepass:env QR_DEBUG_STORE_PASS -alias androiddebugkey" "$tmp/keytool.log" && ! grep -q "PrivateKeyEntry\|Android Debug\|SHA1" "$tmp/out" "$tmp/err"'
reset_logs; run build
check "a debug keystore with the expected certificate: the build runs" \
  '[ "$rc" = 0 ] && [ -f "$tmp/unity.log" ] && [ -f "$tmp/keytool.log" ] && out_has "keystore preflight: .*matches"'


qr_flow_finish
