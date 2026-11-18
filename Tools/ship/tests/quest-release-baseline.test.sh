#!/usr/bin/env bash
# Regression: install A, then rollback prepared B to APK C => next build starts at C, not A or B.
# No Unity, adb, or device access; exercise the real installer and persisted summaries.
# shellcheck disable=SC2016 # Conditions are intentionally evaluated by check.
# shellcheck disable=SC1091 # Sourced script path is computed at runtime.
set -eu
ci_dir="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Tools/ship/quest-release.sh
. "$ci_dir/quest-release.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
qr_test_build_config
QR_LOGS="$tmp/logs"; mkdir -p "$QR_LOGS"
qr_log() { :; }
qr_await_device() { :; }
qr_idle_check() { :; }
qr_verify() { :; } # APK provenance unit tests do not exercise the signer/device preflight.
qr_java_setup() { :; }
qr_device_locked() { "$@"; }
QR_DATA_FILES='playtest.json throws.csv'
qr_device_sha() { echo unchanged; }
qr_backup() { echo "$tmp/backup"; }
qr_mic_state() { echo true; }
qr_adb() {
  : > "$tmp/adb-called"
  [ "${FAIL_ADB:-0}" = 0 ] || return 1
  if [ "${ADB_CREATES_DIRECTORY:-0}" = 1 ]; then mkdir "$QR_LOGS/latest-install" || return 1; fi
  echo Success
}
qr_timestamp() { printf '%s\n' "$now"; }
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; exit 1; fi; }

# Build records must survive verification of a different APK in the same run.
record_build() {
  local sha="$1" apk="$2"
  QR_RUN_DIR="$QR_LOGS/$sha-$now"; mkdir -p "$QR_RUN_DIR"
  qr_set commit "$sha (origin/main)"
  qr_set build_commit "$sha"
  qr_set build_apk_sha256 "$(qr_sha256 "$apk")"
  qr_set apk_sha256 "$(qr_sha256 "$apk")"
}
a="$tmp/A.apk"; c="$tmp/C.apk"; unknown="$tmp/unknown.apk"
printf A > "$a"; printf C > "$c"; printf unknown > "$unknown"
# A prepared-only run verified C; generic hash is deliberately ambiguous legacy metadata.
QR_RUN_DIR="$QR_LOGS/000-prepared"; mkdir -p "$QR_RUN_DIR"
qr_set commit 'bbbbbbbbb (origin/main)'
qr_set apk_sha256 "$(qr_sha256 "$c")"
check 'prepared-only verification never establishes APK build provenance' '[ -z "$(qr_apk_commit "$c")" ]'
now=20251231-000000; qr_rollback "$c"
check 'rollback of verification-only APK persists unknown, not prepared B' '[ -z "$(qr_get installed_commit)" ] && [ -z "$(qr_last_installed_sha)" ]'
now=20260101-000000; record_build ccccccccc "$c"
check 'earlier generic match cannot shadow a genuine immutable build record' '[ "$(qr_apk_commit "$c")" = ccccccccc ]'
c_run="$QR_RUN_DIR"
now=20260102-000000; record_build aaaaaaaaa "$a"
qr_install_apk "$a" 0 install
check 'install records the actual APK commit' '[ "$(qr_get installed_commit)" = aaaaaaaaa ]'
now=20260103-000000
QR_RUN_DIR="$QR_LOGS/bbbbbbbbb-$now"; mkdir -p "$QR_RUN_DIR"
qr_set commit 'bbbbbbbbb (origin/main)'
# Simulate verify replacing these generic fields; immutable build fields still identify A correctly.
printf wrong > "$tmp/wrong.apk"
qr_set apk_sha256 "$(qr_sha256 "$tmp/wrong.apk")"
renamed="$tmp/renamed.apk"; cp "$c" "$renamed"
qr_rollback "$renamed"
check 'rollback records C, not the prepared B commit, even for a renamed APK' '[ "$(qr_get installed_commit)" = ccccccccc ]'
check 'current run rollback is the baseline (not excluded)' '[ "$(qr_last_installed_sha)" = ccccccccc ]'
now=20260104-000000
QR_RUN_DIR="$QR_LOGS/next-$now"; mkdir -p "$QR_RUN_DIR"
check 'a later build uses the rolled-back commit C instead of install A' '[ "$(qr_last_installed_sha)" = ccccccccc ]'
# Updating an older run later must sort by install time, not its preparation directory timestamp.
QR_RUN_DIR="$c_run"; now=20260105-000000
qr_install_apk "$a" 0 install
check 'explicit install of another run APK records A, not the current prepared C' '[ "$(qr_get installed_commit)" = aaaaaaaaa ]'
check 'latest operation wins even inside an older run directory' '[ "$(qr_last_installed_sha)" = aaaaaaaaa ]'
# A refused/failed adb install must not overwrite the actually installed baseline.
now=20260106-000000
if ( FAIL_ADB=1; qr_install_apk "$c" 0 rollback ); then exit 1; fi
check 'failed install keeps the last actual installed commit' '[ "$(qr_last_installed_sha)" = aaaaaaaaa ]'
# Fail only the atomic publication, not summary writes or adb. The old file
# remains on disk alongside a same-second legacy row, but neither is trusted.
for fault in write rename; do
  qr_install_apk "$a" 0 install
  rm -f "$tmp/adb-called"
  if (
    mktemp() {
      case "$fault:$*" in write:*latest-install*) printf '%s\n' "$QR_LOGS/missing/record"; return ;; esac
      command mktemp "$@"
    }
    perl() {
      case "$fault:${*: -1}" in rename:*/latest-install) return 1 ;; esac
      command perl "$@"
    }
    qr_install_apk "$c" 0 rollback
  ) > "$tmp/failure.out" 2>&1; then
    echo "FAIL publication $fault: unexpectedly succeeded"; exit 1
  fi
  check "publication $fault: reports real adb success but no authoritative baseline" \
    '[ -f "$tmp/adb-called" ] && grep -qx Success "$QR_RUN_DIR/rollback-adb.log" &&
      [[ "$(qr_get install)" == "rollback: adb install ok"*"provenance publication failed"* ]] &&
      [ "$(head -n1 "$QR_LOGS/latest-install")" = aaaaaaaaa ] && [ -z "$(qr_last_installed_sha)" ]'
  if ( FAIL_ADB=1; qr_install_apk "$c" 0 rollback ); then exit 1; fi
  check "publication $fault: later adb failure does not revive the stale baseline" '[ -z "$(qr_last_installed_sha)" ]'
  qr_install_apk "$c" 0 rollback
  check "publication $fault: successful retry publishes the new baseline" '[ "$(qr_last_installed_sha)" = ccccccccc ]'
done

for destination in directory symlink; do
  rm -f "$tmp/adb-called" "$QR_LOGS/latest-install"
  if [ "$destination" = directory ]; then
    dir="$QR_LOGS/latest-install"; mkdir "$dir"
  else
    dir="$tmp/link-target"; mkdir "$dir"; ln -s "$dir" "$QR_LOGS/latest-install"
  fi
  if ( qr_install_apk "$c" 0 install ) > "$tmp/failure.out" 2>&1; then
    echo "FAIL $destination destination: unexpectedly succeeded"; exit 1
  fi
  check "$destination destination blocks adb and is not used as a legacy baseline or move target" \
    '[ ! -e "$tmp/adb-called" ] && [ -z "$(ls -A "$dir")" ] && [ -z "$(qr_last_installed_sha)" ]'
  if [ "$destination" = symlink ]; then rm "$QR_LOGS/latest-install"; fi
  rmdir "$dir"
done
# A directory appearing after preflight must make publication fail rather
# than silently receive the temp file as a child.
if ( ADB_CREATES_DIRECTORY=1; qr_install_apk "$c" 0 install ) > "$tmp/failure.out" 2>&1; then
  echo 'FAIL directory appeared during adb: unexpectedly succeeded'; exit 1
fi
check 'directory appearing during adb is not used as a move target' \
  '[[ "$(qr_get install)" == "install: adb install ok"*"provenance publication failed"* ]] &&
    [ -z "$(ls -A "$QR_LOGS/latest-install")" ] && [ -z "$(qr_last_installed_sha)" ]'
rmdir "$QR_LOGS/latest-install"
qr_install_apk "$unknown" 0 install
check 'unknown APK clears the baseline instead of claiming the prepared commit' '[ -z "$(qr_last_installed_sha)" ]'
# Legacy prepared commits are not build evidence for an explicitly supplied, now-missing APK.
rm -rf "$QR_LOGS"; mkdir -p "$QR_LOGS/legacy-20200101-000000/summary"
printf 'install ok (/old.apk)\n' > "$QR_LOGS/legacy-20200101-000000/summary/install"
printf 'ddddddddd (origin/main)\n' > "$QR_LOGS/legacy-20200101-000000/summary/commit"
QR_RUN_DIR="$QR_LOGS/current"
check 'legacy install with missing APK does not invent provenance from its prepared commit' '[ -z "$(qr_last_installed_sha)" ]'
# Exercise the build's notes selection with a fake editor: unknown means last-eight-merges fallback.
QR_SHA=fffffffff; QR_SHORT=fffffffff; QR_APK_REL=out.apk; QR_APK_DIR="$tmp/apks"
QR_KEYSTORE_CHECKED=1; QR_BUILD_TIMEOUT=10
mkdir -p "$QR_RUN_DIR" "$tmp/build"
qr_need_commit() { :; }
qr_check_prepared_worktree() { :; } # Covered by the prepared-integrity fixture.
qr_wt() { echo "$tmp/build"; }
qr_android_user_home() { echo "$tmp/android"; }
unity() { printf '%s' "${YETIKIT_PREV_SHA:-}" > "$tmp/editor-prev"; printf built > "$tmp/build/out.apk"; }
unset YETIKIT_PREV_SHA YETIKIT_WHATS_NEW
qr_build > /dev/null
check 'missing legacy install APK selects last-eight-merges notes fallback' \
  '[ ! -s "$tmp/editor-prev" ] && [ "$(qr_get notes)" = "merge titles since the last 8 merges" ]'
mkdir -p "$QR_LOGS/legacy-20200102-000000/summary"
printf 'rollback ok (/older.apk)\n' > "$QR_LOGS/legacy-20200102-000000/summary/install"
printf 'eeeeeeeee (origin/main)\n' > "$QR_LOGS/legacy-20200102-000000/summary/commit"
check 'legacy rollback never misattributes its prepared commit' '[ -z "$(qr_last_installed_sha)" ]'
# If the legacy rollback APK is still available, resolve its build provenance instead of discarding it.
now=19990101-000000; record_build ccccccccc "$c"
printf 'rollback ok (%s)\n' "$c" > "$QR_LOGS/legacy-20200102-000000/summary/install"
check 'legacy rollback can recover the actual APK commit from its build record' '[ "$(qr_last_installed_sha)" = ccccccccc ]'

# Historical summaries can name a configured file, or use the generic data marker.
marked_apk="$tmp/C (copy).apk"; cp "$c" "$marked_apk"
QR_DATA_FILES='session-data_2.json'
for marker in "$QR_DATA_FILES" data playtest.json; do
  printf 'rollback ok (%s), %s CHANGED\n' "$marked_apk" "$marker" > "$QR_LOGS/legacy-20200102-000000/summary/install"
  check "legacy CHANGED marker for $marker preserves APK provenance" '[ "$(qr_last_installed_sha)" = ccccccccc ]'
done
echo 'all passed'
