#!/usr/bin/env bash
# Synthetic macOS filename collisions and completed-backup integrity checks.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
config="$ship/lib/config.jq"
base='{"schema":1,"unityVersion":"fixture","build":{"devMethod":"Fixture.Dev","releaseMethod":"Fixture.Release","apkPath":"out.apk"},"quest":{"package":"com.example.fixture"}}'
for names in '["SHA256SUMS"]' '["sha256sums"]' '["Sha256Sums"]' '["data.json","DATA.JSON"]' '["data.json","data.json"]'; do
  result="$(jq --argjson names "$names" '.quest.dataFiles = $names' <<< "$base" | jq -rs -f "$config")"
  [ "$result" = 'missing or invalid key: quest.dataFiles' ] || { echo "FAIL: accepted $names"; exit 1; }
done
for names in '[]' '["data.json","other.csv"]'; do
  [ -z "$(jq --argjson names "$names" '.quest.dataFiles = $names' <<< "$base" | jq -rs -f "$config")" ]
done
echo 'PASS: manifest aliases and case-folded duplicate destinations rejected'

. "$ship/quest-release/common.sh"
. "$ship/quest-release/device.sh"
printf 'synthetic first payload\n' > "$tmp/first.json"
printf 'synthetic second payload\n' > "$tmp/second.csv"
QR_DATA_FILES='first.json second.csv missing.json'
QR_DATA_DIR=/synthetic
qr_log() { printf '%s\n' "$*" >&2; }
qr_device_locked() { "$@"; }
qr_java_setup() { :; }
qr_verify() { :; }
qr_await_device() { :; }
qr_idle_check() { :; }
qr_device_sha() {
  if [ "$1" = missing.json ]; then echo missing; else qr_sha256 "$tmp/$1"; fi
}
qr_adb() {
  case "$1" in
    exec-out)
      cat "$tmp/${3##*/}"
      # Simulate a previously checked payload changing while a later one is copied.
      if [ "${corrupt:-0}" = 1 ] && [ "${3##*/}" = second.csv ]; then
        printf damaged > "$QR_BACKUP_ROOT"/*/first.json
      fi ;;
    install) touch "$tmp/install-called"; echo Success ;;
    *) return 1 ;;
  esac
}
qr_mic_state() { echo false; }
qr_apk_commit() { echo fixture; }
printf apk > "$tmp/fixture.apk"
for mode in intact corrupt; do
  mkdir -p "$tmp/$mode/backups" "$tmp/$mode/run"
  QR_BACKUP_ROOT="$tmp/$mode/backups"; QR_RUN_DIR="$tmp/$mode/run"
  corrupt=0; [ "$mode" != corrupt ] || corrupt=1
  rc=0
  # Production does not enable errexit: failure must be handled explicitly.
  (set +e; qr_install_apk_locked "$tmp/fixture.apk" 0 install) > "$tmp/$mode.out" 2>&1 || rc=$?
  if [ "$mode" = intact ]; then
    [ "$rc" = 0 ] && [ -f "$tmp/install-called" ]
    backup="$(find "$QR_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)"
    (cd "$backup"; sha256sum -c SHA256SUMS)
    [ "$(wc -l < "$backup/SHA256SUMS")" = 2 ]
    cmp "$tmp/first.json" "$backup/first.json"
    cmp "$tmp/second.csv" "$backup/second.csv"
    rm "$tmp/install-called"
    echo 'PASS: complete backup verifies; absent data file is omitted; install proceeds'
  else
    [ "$rc" != 0 ] && [ ! -e "$tmp/install-called" ]
    [ ! -e "$QR_RUN_DIR/summary/backup" ]
    grep -q 'completed backup' "$tmp/$mode.out"
    echo 'PASS: corruption after individual verification blocks installation and verified summary'
  fi
done
