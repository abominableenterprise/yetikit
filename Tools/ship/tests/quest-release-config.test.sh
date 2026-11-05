#!/usr/bin/env bash
# Config/env/device discovery smoke checks. Synthetic adb only; never a headset or editor.
# shellcheck disable=SC2016 # check evaluates assertions in this shell.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$here/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
. "$here/../quest-release.sh"
export QUEST_REPO="$tmp/repo" HOME="$tmp/home"
mkdir -p "$QUEST_REPO" "$HOME"
base="$tmp/base.json"; cp "$YETIKIT_CONFIG" "$base"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ ! -f "$tmp/err" ] || tail -n 8 "$tmp/err"; fails=$((fails + 1)); fi; }
load() { rc=0; ( qr_config ) > "$tmp/out" 2> "$tmp/err" || rc=$?; }
mutate() { jq "$1" "$base" > "$YETIKIT_CONFIG"; }

load
check 'schema 1 synthetic Quest config accepted' '[ "$rc" = 0 ]'
for expression in '.schema = 2' 'del(.quest.package)' '.quest.package = ""' '.quest.package = "bad/package"' \
  '.quest = []' '.quest.serial = "synthetic-device"' 'del(.build.devMethod)' '.build.apkPath = "../outside.apk"' \
  '.quest.launcherChecks.permissions = "not-an-array"' '.quest.launcherChecks.assets = ["../outside"]' \
  '.quest.apkKeepName = "../outside-{sha}.apk"' '.quest.whatsNewEnv = "NOT-AN-ENV"' \
  '.quest.prevShaEnv = "BAD=ENV"' '.quest.dataFiles = ["../outside"]' \
  '.quest.dataFiles = ["SHA256SUMS"]' '.quest.dataFiles = ["playtest.json", "SHA256SUMS"]' \
  '.quest.launchArgs = "not-an-array"'; do
  mutate "$expression"; load
  check "rejects invalid config: $expression" '[ "$rc" != 0 ]'
done
mutate 'del(.quest)'
load
check 'Quest entry point requires quest block' '[ "$rc" != 0 ]'
# The schema is shared: non-Quest consumers may omit the entire block.
rc=0; schema_error="$(jq -sr -f "$here/../lib/config.jq" "$YETIKIT_CONFIG")" || rc=$?
check 'shared schema accepts config without quest' '[ "$rc" = 0 ] && [ -z "$schema_error" ]'
mutate 'del(.quest.apkKeepName, .quest.perfLogTag, .quest.launcherChecks)'
load
check 'optional Quest fields can be omitted' '[ "$rc" = 0 ]'
mutate '.quest.dataFiles = [] | .quest.launchArgs = ["--es", "synthetic.mode", "release"]'
rc=0
( qr_config && [ -z "$QR_DATA_FILES" ] && [ "$(printf "%s" "$QR_LAUNCH_ARGS" | jq -r ".[2]")" = release ] ) 2> "$tmp/err" || rc=$?
check 'empty data list and JSON launch args preserved' '[ "$rc" = 0 ]'
cp "$base" "$YETIKIT_CONFIG"
rc=0
(
  unset QR_LAUNCH_WAIT QR_ADB_WAIT QR_GATE_TIMEOUT QR_BUILD_TIMEOUT QUEST_LAUNCH_WAIT QUEST_ADB_WAIT QUEST_GATE_TIMEOUT QUEST_BUILD_TIMEOUT
  qr_config || exit 1
  [ "$QR_BUILD_METHOD" = Synthetic.Editor.Build.DevelopmentApk ] &&
  [ "$QR_APK_REL" = Builds/Android/consumer-dev.apk ] &&
  [ "$QR_APK_KEEP_NAME" = 'consumer-dev-{sha}.apk' ] &&
  [ "$QR_PERF_LOG_TAG" = '[SyntheticPerf]' ] &&
  [ "$QR_WHATS_NEW_ENV" = YETIKIT_WHATS_NEW ] && [ "$QR_PREV_SHA_ENV" = YETIKIT_PREV_SHA ] &&
  [ "$QR_ROOT" = "$HOME/wt/repo" ] && [ "$QR_LAUNCH_WAIT" = 60 ] && [ "$QR_ADB_WAIT" = 120 ]
) 2> "$tmp/err" || rc=$?
check 'standard build fields, keep pattern, tag, notes defaults and worktree default loaded' '[ "$rc" = 0 ]'
mutate '.quest.whatsNewEnv = "SYNTHETIC_NOTES" | .quest.prevShaEnv = "SYNTHETIC_PREV" | del(.quest.perfLogTag)'
rc=0
( qr_config && [ "$QR_WHATS_NEW_ENV" = SYNTHETIC_NOTES ] && [ "$QR_PREV_SHA_ENV" = SYNTHETIC_PREV ] && [ -z "$QR_PERF_LOG_TAG" ] ) 2> "$tmp/err" || rc=$?
check 'custom notes env names and absent perf tag supported' '[ "$rc" = 0 ]'
cp "$base" "$YETIKIT_CONFIG"
rc=0
(
  unset QR_LAUNCH_WAIT QR_ADB_WAIT QR_GATE_TIMEOUT QR_BUILD_TIMEOUT
  QUEST_LAUNCH_WAIT=3 QUEST_ADB_WAIT=4 QUEST_GATE_TIMEOUT=5 QUEST_BUILD_TIMEOUT=6 qr_config || exit 1
  [ "$QR_LAUNCH_WAIT,$QR_ADB_WAIT,$QR_GATE_TIMEOUT,$QR_BUILD_TIMEOUT" = 3,4,5,6 ] || exit 1
  QR_LAUNCH_WAIT=7 QR_ADB_WAIT=8 QR_GATE_TIMEOUT=9 QR_BUILD_TIMEOUT=10
  QUEST_LAUNCH_WAIT=3 QUEST_ADB_WAIT=4 QUEST_GATE_TIMEOUT=5 QUEST_BUILD_TIMEOUT=6 qr_config || exit 1
  [ "$QR_LAUNCH_WAIT,$QR_ADB_WAIT,$QR_GATE_TIMEOUT,$QR_BUILD_TIMEOUT" = 7,8,9,10 ]
) 2> "$tmp/err" || rc=$?
check 'QR timeout overrides take precedence over legacy QUEST aliases' '[ "$rc" = 0 ]'
for seconds in 0 -1 nope 08; do
  rc=0; ( QR_ADB_WAIT="$seconds"; qr_config ) 2> "$tmp/err" || rc=$?
  check "invalid timeout $seconds rejected" '[ "$rc" != 0 ]'
done
for fingerprint in '' AA:BB not-hex; do
  rc=0; ( QUEST_CERT_SHA256="$fingerprint"; qr_require_certificate ) 2> "$tmp/err" || rc=$?
  check 'missing or malformed signer is refused' '[ "$rc" != 0 ] && grep -q QUEST_CERT_SHA256 "$tmp/err"'
done
rc=0; ( qr_require_certificate; [ "$QR_CERT_SHA256" = 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff ] ) || rc=$?
check 'synthetic env signer normalized, never baked into config' '[ "$rc" = 0 ] && ! grep -q CERT "$YETIKIT_CONFIG"'

adb() {
  printf '%s\n' "$*" >> "$tmp/adb.log"
  [ "$1" = devices ] || return 1
  printf 'List of devices attached\n'
  case "$FAKE_DEVICES" in
    one) printf 'synthetic-device\tdevice\n' ;;
    two) printf 'synthetic-device\tdevice\nsynthetic-other\tdevice\n' ;;
    none) : ;;
  esac
}
for scenario in one none two; do
  rc=0
  ( QUEST_SERIAL=''; FAKE_DEVICES="$scenario"; qr_select_device && [ "$QUEST_SERIAL" = synthetic-device ] ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [ "$scenario" = one ]; then
    check 'one attached device autodetected' '[ "$rc" = 0 ]'
  else
    check "$scenario attached devices refuse ambiguous autodetect" '[ "$rc" != 0 ] && grep -q "set QUEST_SERIAL" "$tmp/err"'
  fi
done
rm -f "$tmp/adb.log"
rc=0; ( QUEST_SERIAL=synthetic-explicit; qr_select_device && [ "$QUEST_SERIAL" = synthetic-explicit ] ) || rc=$?
check 'explicit QUEST_SERIAL avoids discovery' '[ "$rc" = 0 ] && [ ! -f "$tmp/adb.log" ]'
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
