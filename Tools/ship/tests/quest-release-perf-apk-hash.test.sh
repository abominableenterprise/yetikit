#!/usr/bin/env bash
# Installed APK hashing accepts normal encoded paths but never shell syntax.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release/perf.sh"
QUEST_SERIAL=synthetic
QR_PKG=com.example.synthetic
sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
fixture_path='/data/app/~~Synthetic+Token==/com.example.synthetic-Token_1==/base.apk'
fault=''
qr_timebox() {
  [ "$1" = 5 ] && [ "$2" = adb ] && [ "$3" = -s ] && [ "$4" = "$QUEST_SERIAL" ] && [ "$5" = shell ] || return 99
  shift 5
  case "$1" in
    pm)
      [ "$fault" != path ] || return 1
      [ "$2" = path ] && [ "$3" = "$QR_PKG" ] || return 99
      printf 'package:%s\r\n' "$fixture_path" ;;
    sha256sum)
      [ "$fault" != hash ] || return 1
      [ "$#" = 2 ] && [ "$2" = "$fixture_path" ] || return 99
      printf '%s  %s\n' "$sha" "$fixture_path" ;;
    *) return 99 ;;
  esac
}
[ "$(qr_perf_apk_sha)" = "$sha" ] || { echo 'FAIL encoded installed APK path'; exit 1; }
echo 'ok encoded installed APK path'
for fault in path hash; do
  [ "$(qr_perf_apk_sha)" = unavailable ] || exit 1
done
fault=''
fixture_path='/data/app/$(unsafe)/base.apk'
[ "$(qr_perf_apk_sha)" = unavailable ] || exit 1
echo 'ok query failures and unsafe paths remain unavailable'
