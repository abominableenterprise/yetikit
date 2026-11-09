#!/usr/bin/env bash
# Synthetic keystores/editor/APKs only; no JDK, Unity, credentials or device required.
# shellcheck disable=SC2016 # check evaluates assertions in this shell.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$here/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
. "$here/../quest-release.sh"
export QUEST_REPO="$tmp/repo" HOME="$tmp/home" QUEST_WT_ROOT="$tmp/wt" ANDROID_SDK_ROOT="$tmp/sdk"
mkdir -p "$QUEST_REPO" "$HOME" "$ANDROID_SDK_ROOT"
base="$tmp/base.json"; cp "$YETIKIT_CONFIG" "$base"
# Values are synthetic, deliberately distinct from paths, aliases and fingerprints.
export SYNTHETIC_STORE_PATH="$tmp/release.p12" SYNTHETIC_STORE_PASS='synthetic-store-secret-7391' \
  SYNTHETIC_KEY_ALIAS=release SYNTHETIC_KEY_PASS='synthetic-key-secret-8462'
cert="$(qr_norm_hex "$QUEST_CERT_SHA256")"
other=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
printf '%s\n' "$cert" > "$SYNTHETIC_STORE_PATH"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
configure() {
  jq '.quest.signing = {
    "keystorePathEnv": "SYNTHETIC_STORE_PATH",
    "storePassEnv": "SYNTHETIC_STORE_PASS",
    "keyAliasEnv": "SYNTHETIC_KEY_ALIAS",
    "keyPassEnv": "SYNTHETIC_KEY_PASS"
  }' "$base" > "$YETIKIT_CONFIG"
}
# Like the debug-key fixture, use fake keytool; record argv but never environment values.
keytool() {
  local path='' alias='' passenv='' prev='' arg
  printf '%s\n' "$*" >> "$tmp/keytool.argv"
  for arg in "$@"; do
    case "$prev" in -keystore) path="$arg" ;; -alias) alias="$arg" ;; -storepass:env) passenv="$arg" ;; esac
    case "$arg" in -storepass|-keypass) return 1 ;; esac
    prev="$arg"
  done
  [ "$alias" = release ] && [ "$passenv" = SYNTHETIC_STORE_PASS ] || return 1
  [ "$(printenv "$passenv")" = "$SYNTHETIC_STORE_PASS" ] || return 1
  [ "${FAKE_KEYTOOL_RC:-0}" = 0 ] || { echo "SHA256: $cert"; return 1; }
  printf 'Certificate fingerprints:\n  SHA256: %s\n' "$(head -n1 "$path")"
}
unity() {
  local prev='' project='' arg
  echo editor >> "$tmp/editor"
  # Check a real child environment, not just the wrapper's shell variables. Never print secrets.
  [ "$(printenv SYNTHETIC_STORE_PASS)" = "$SYNTHETIC_STORE_PASS" ] &&
    [ "$(printenv SYNTHETIC_KEY_PASS)" = "$SYNTHETIC_KEY_PASS" ] &&
    [ "$(printenv SYNTHETIC_STORE_PATH)" = "$SYNTHETIC_STORE_PATH" ] &&
    [ "$(printenv SYNTHETIC_KEY_ALIAS)" = "$SYNTHETIC_KEY_ALIAS" ] || return 1
  [ -z "${XDG_CONFIG_HOME:-}" ] || [ "$(printenv XDG_CONFIG_HOME)" = "$XDG_CONFIG_HOME" ] || return 1
  for arg in "$@"; do [ "$prev" != -projectPath ] || project="$arg"; prev="$arg"; done
  mkdir -p "$project/Builds/Android"
  echo synthetic-apk > "$project/Builds/Android/consumer-dev.apk"
}
qr_java_setup() { return 0; }
qr_last_installed_sha() { :; }
qr_doctor_java() { return 0; }
qr_doctor_apksigner() { :; }
qr_doctor_unity() { :; }
qr_doctor_disk() { :; }
qr_doctor_device() { :; }
qr_doctor_running() { :; }
python3() { return 0; }
apksigner() { printf 'Signer #1 certificate SHA-256 digest: %s\n' "${FAKE_APK_CERT:-$cert}"; }
qr_await_device() { :; }
qr_idle_check() { :; }
qr_backup() { mkdir -p "$tmp/backup"; printf '%s\n' "$tmp/backup"; }
qr_mic_state() { echo true; }
qr_adb() { printf '%s\n' "$*" >> "$tmp/adb.argv"; echo Success; }
qr_apk_commit() { :; }
configure
qr_config || exit 1
mkdir -p "$QR_LOGS"
qr_new_run 0123456789012345678901234567890123456789 synthetic
mkdir -p "$(qr_wt build)"
# all still calls the real preflight and must stop before parallel editors on failure.
qr_prepare() { qr_load_state; }
qr_parallel_unity() { echo parallel >> "$tmp/editor"; QR_GATE_RC=0; QR_BUILD_RC=1; }
run() {
  local label="$1"; shift
  rc=0
  ( qr_main "$@" ) > "$tmp/$label.out" 2> "$tmp/$label.err" || rc=$?
}
run p12 build
check 'PKCS12 matching release certificate permits build with inherited signing env' '[ "$rc" = 0 ] && [ -f "$tmp/editor" ]'
check 'keytool uses an environment password source and configured alias' 'grep -q -- "-storepass:env SYNTHETIC_STORE_PASS -alias release" "$tmp/keytool.argv"'
run doctor-p12 doctor
check 'doctor reports custom PKCS12 keystore ok' '[ "$rc" = 0 ] && grep -q "^ok .*keystore.*SYNTHETIC_STORE_PATH.*matches" "$tmp/doctor-p12.out"'
export SYNTHETIC_STORE_PATH="$tmp/release.jks"
printf '%s\n' "$cert" > "$SYNTHETIC_STORE_PATH"
run jks build
check 'JKS also permits build using keytool autodetection' '[ "$rc" = 0 ]'
# The optional key password is not needed for certificate inspection.
jq 'del(.quest.signing.keyPassEnv)' "$YETIKIT_CONFIG" > "$tmp/no-keypass.json"
cp "$tmp/no-keypass.json" "$YETIKIT_CONFIG"
run no-keypass doctor
check 'keyPassEnv can be omitted' '[ "$rc" = 0 ]'
configure
# Custom signing must not scrub environment names used by the consumer, including XDG_CONFIG_HOME.
export XDG_CONFIG_HOME="$tmp/xdg"
run inherited-xdg build
check 'custom build preserves XDG_CONFIG_HOME in the inherited environment' '[ "$rc" = 0 ]'
unset XDG_CONFIG_HOME
FAKE_KEYTOOL_RC=1 run keytool-failed build
check 'failed keytool cannot pass using a fingerprint in its failed output' '[ "$rc" != 0 ] && grep -q "could not read" "$tmp/keytool-failed.err"'
printf '%s\n' "$other" > "$SYNTHETIC_STORE_PATH"
for cmd in build all; do
  rm -f "$tmp/editor"
  run "wrong-$cmd" "$cmd"
  check "$cmd rejects another certificate before any editor starts" '[ "$rc" != 0 ] && [ ! -f "$tmp/editor" ]'
done
run wrong-doctor doctor
check 'doctor FAILs for another certificate' '[ "$rc" != 0 ] && grep -q "^FAIL .*keystore" "$tmp/wrong-doctor.out"'
printf '%s\n' "$cert" > "$SYNTHETIC_STORE_PATH"
for name in SYNTHETIC_STORE_PATH SYNTHETIC_STORE_PASS SYNTHETIC_KEY_ALIAS SYNTHETIC_KEY_PASS; do
  rc=0
  rm -f "$tmp/editor"
  ( unset "$name"; qr_main build ) > "$tmp/unset-$name.out" 2> "$tmp/unset-$name.err" || rc=$?
  check "unset $name fails before Unity naming only the variable" '[ "$rc" != 0 ] && [ ! -f "$tmp/editor" ] && grep -q "$name" "$tmp/unset-$name.err"'
  rc=0
  ( export "$name="; qr_main doctor ) > "$tmp/empty-$name.out" 2> "$tmp/empty-$name.err" || rc=$?
  check "empty $name makes doctor FAIL" '[ "$rc" != 0 ] && grep -q "^FAIL .*keystore.*$name" "$tmp/empty-$name.out"'
done
rc=0
( SYNTHETIC_STORE_PATH="$tmp/absent-private-path.pfx"; qr_main build ) > "$tmp/missing.out" 2> "$tmp/missing.err" || rc=$?
check 'missing custom file fails naming the env var, not its path value' '[ "$rc" != 0 ] && grep -q SYNTHETIC_STORE_PATH "$tmp/missing.err" && ! grep -q absent-private-path "$tmp/missing.err"'
rc=0
( SYNTHETIC_STORE_PATH="$tmp/absent-private-path.pfx"; qr_main doctor ) > "$tmp/missing-doctor.out" 2> "$tmp/missing-doctor.err" || rc=$?
check 'doctor FAILs on missing custom file without printing its value' '[ "$rc" != 0 ] && grep -q "^FAIL .*SYNTHETIC_STORE_PATH" "$tmp/missing-doctor.out" && ! grep -q absent-private-path "$tmp/missing-doctor.out"'
# Invalid config must fail safely before indirect expansion, even on prebuilt commands.
for expression in '.quest.signing = null' '.quest.signing = []' '.quest.signing = {}' \
  'del(.quest.signing.storePassEnv)' '.quest.signing.keyAliasEnv = "BAD-NAME"' \
  '.quest.signing.keyPassEnv = ""'; do
  configure
  jq "$expression" "$YETIKIT_CONFIG" > "$tmp/invalid.json"; cp "$tmp/invalid.json" "$YETIKIT_CONFIG"
  run invalid doctor
  check "invalid signing configuration rejected: $expression" '[ "$rc" != 0 ] && grep -q quest.signing "$tmp/invalid.err"'
done
configure
# Prebuilt commands must not resolve signing variables at all. Keep actual verifier and installer.
jq '.quest.dataFiles = []' "$YETIKIT_CONFIG" > "$tmp/prebuilt.json"; cp "$tmp/prebuilt.json" "$YETIKIT_CONFIG"
echo synthetic-apk > "$tmp/prebuilt.apk"
rm -f "$tmp/keytool.argv" "$tmp/adb.argv"
for cmd in install verify rollback; do
  rc=0
  ( unset SYNTHETIC_STORE_PATH SYNTHETIC_STORE_PASS SYNTHETIC_KEY_ALIAS SYNTHETIC_KEY_PASS; qr_main "$cmd" "$tmp/prebuilt.apk" ) > "$tmp/prebuilt-$cmd.out" 2> "$tmp/prebuilt-$cmd.err" || rc=$?
  check "prebuilt $cmd works with all signing variables unset" '[ "$rc" = 0 ] && [ ! -f "$tmp/keytool.argv" ]'
done
check 'prebuilt install actually reaches adb install -r' 'grep -q "install -r " "$tmp/adb.argv"'
rc=0
( unset SYNTHETIC_STORE_PATH SYNTHETIC_STORE_PASS SYNTHETIC_KEY_ALIAS SYNTHETIC_KEY_PASS; FAKE_APK_CERT="$other"; qr_main verify "$tmp/prebuilt.apk" ) > "$tmp/prebuilt-wrong.out" 2> "$tmp/prebuilt-wrong.err" || rc=$?
check 'prebuilt verify rejects wrong APK signer without a keystore' '[ "$rc" != 0 ] && grep -q "not the expected" "$tmp/prebuilt-wrong.err"'
# Scan every run file, summary, recorded argv and captured output; do not echo a matching line.
check 'password values never appear in any output, argv or run file' '! grep -r -F -q -e "$SYNTHETIC_STORE_PASS" -e "$SYNTHETIC_KEY_PASS" "$tmp"'
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
