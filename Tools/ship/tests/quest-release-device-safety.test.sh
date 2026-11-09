#!/usr/bin/env bash
# Focused device data safety regressions; fake adb only, no headset or Unity needed.
# Run: bash Tools/ship/tests/quest-release-device-safety.test.sh
set -u
. "$(dirname "$0")/../quest-release/device.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
QR_DATA_DIR="$tmp/device"
QR_BACKUP_ROOT="$tmp/backups"
QR_RUN_DIR="$tmp/run"
QR_DATA_FILES='playtest.json throws.csv'
mkdir -p "$QR_DATA_DIR" "$QR_BACKUP_ROOT" "$QR_RUN_DIR"
printf '%s\n' '{"uploadKey":"synthetic-private-value"}' > "$QR_DATA_DIR/playtest.json"
printf 'throw,data\n' > "$QR_DATA_DIR/throws.csv"
printf 'apk\n' > "$tmp/game.apk"

qr_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
qr_log() { printf '%s\n' "$*" >&2; }
qr_set() { printf '%s\n' "$2" > "$QR_RUN_DIR/$1"; }
qr_get() { :; }
qr_timestamp() { printf '20260101-000000\n'; }
qr_sha256() { sha256sum "$1" | awk '{print $1}'; }
qr_apk_commit() { :; } # This fixture tests device safety, not release-build provenance.
qr_check_device() { :; }
qr_java_setup() { :; }
qr_device_locked() { "$@"; } # Lock protocol is covered independently.
qr_idle_check() { :; }
# Standalone installation must verify the APK before touching device data.
qr_verify() { printf '%s\n' "$1" >> "$tmp/verify-count"; [ "${VERIFY_FAIL:-0}" = 0 ]; }

# Execute the real remote test/hash command unless simulating an adb/storage fault.
adb() {
  [ "$1" = -s ] && [ "$2" = "$QUEST_SERIAL" ] || return 1
  shift 2
  case "$1" in
    shell)
      shift
      case "$1" in
        *sha256sum*)
          if [ "${STORAGE_DENIED:-0}" = 1 ]; then
            # A blocked directory makes -f false. A probe of the directory must NOT call this absence.
            case "$1" in *'ls -A'*) printf 'inaccessible\n' ;; *) printf 'missing\n' ;; esac
            return 0
          fi
          if [ "${SECOND_LIST_FAIL:-0}" = 1 ]; then
            # The directory can be entered, but its contents cannot be listed. It must not report missing.
            printf 'unknown\n'; return 0
          fi
          if [ "${FILE_DENIED:-0}" = 1 ] && [[ "$1" == *throws.csv* ]]; then
            printf 'unknown\n'; return 0
          fi
          if [ "${SHELL_ERROR:-0}" = 1 ] || [ -f "$tmp/after-install-error" ]; then
            # Some adb failures still produce stdout; the caller must check adb's exit status.
            printf '%s  %s\n' "$(qr_sha256 "$QR_DATA_DIR/playtest.json")" "$QR_DATA_DIR/playtest.json"
            return 1
          fi
          bash -c "$1" ;;
        *) bash -c "$1" ;;
      esac ;;
    exec-out) [ "$2" = cat ] && cat "$3" ;;
    install) printf 'installed\n' >> "$tmp/install-count"; printf 'Success\n'
      if [ "${AFTER_INSTALL_ERROR:-0}" = 1 ]; then : > "$tmp/after-install-error"; fi ;;
    *) return 1 ;;
  esac
}

fails=0
check() { if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fails=$((fails+1)); fi; }
run() {
  rm -f "$tmp/install-count" "$tmp/after-install-error" "$tmp/verify-count"
  rc=0
  ( qr_install_apk "$tmp/game.apk" 0 install ) > "$tmp/out" 2> "$tmp/err" || rc=$?
}
VERIFY_FAIL=1 run
check 'standalone install invokes verification and refuses a rejected APK' \
  '[ "$rc" != 0 ] && [ "$(cat "$tmp/verify-count")" = "$tmp/game.apk" ] && [ ! -f "$tmp/install-count" ]'

# A missing file really is optional, provided the parent directory can be listed.
rm "$QR_DATA_DIR/throws.csv"
run
check 'genuinely absent optional file allows a verified install' '[ "$rc" = 0 ] && [ -f "$tmp/install-count" ]'
printf 'throw,data\n' > "$QR_DATA_DIR/throws.csv"

STORAGE_DENIED=1 run
check 'unreadable storage is not mistaken for missing playtest.json' \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/install-count" ] && grep -q "cannot hash playtest.json" "$tmp/err"'
SECOND_LIST_FAIL=1 run
check 'failed directory listing does not count as missing' \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/install-count" ] && grep -q "cannot hash playtest.json" "$tmp/err"'
FILE_DENIED=1 run
check 'unreadable optional throws.csv blocks backup and install' \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/install-count" ] && grep -q "cannot hash throws.csv" "$tmp/err"'

SHELL_ERROR=1 run
check 'adb shell status failure with hash-like stdout blocks install' \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/install-count" ]'

# A read failure AFTER a successful install must be reported as a failed safety check, not a valid changed hash.
# Use a dedicated stub state file because install runs in a command substitution.
AFTER_INSTALL_ERROR=1 run
check 'post-install hash read error fails closed' \
  '[ "$rc" != 0 ] && [ -f "$tmp/install-count" ] && grep -q "cannot hash playtest.json" "$tmp/err"'

# An early missing-APK refusal must replace the previous attempt's successful status, for both labels.
for label in install rollback; do
  printf '%s ok (old.apk)\n' "$label" > "$QR_RUN_DIR/install"
  rc=0
  ( qr_install_apk "$tmp/missing.apk" 0 "$label" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  check "$label missing APK replaces stale success with this attempt's refusal" \
    '[ "$rc" != 0 ] && grep -q "^$label stopped before adb install" "$QR_RUN_DIR/install" && grep -q "no APK" "$tmp/err"'
done

if [ "$fails" != 0 ]; then printf '%s failed\n' "$fails"; exit 1; fi
printf 'all passed\n'
