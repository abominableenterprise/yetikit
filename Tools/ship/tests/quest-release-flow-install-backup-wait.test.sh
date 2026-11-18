#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build

reset_logs; run install "$apk"
backup="$(find "$HOME" -maxdepth 1 -name 'Quest-playtest-backup-*' | sort | tail -n1)"
check "install: verifies before adb install -r, with -s on every adb call; no destructive command" \
  '[ -f "$tmp/py.log" ] && [ "$rc" = 0 ] && grep -q "^-s $serial install -r $apk$" "$tmp/adb.log" && [ ! -f "$tmp/adb-no-serial" ] && ! grep -qE "uninstall|pm clear|grant|revoke" "$tmp/adb.log"'
check "the backup has both files from exec-out cat, matching SHA256SUMS" \
  'grep -q "exec-out cat /sdcard/Android/data/com.example.consumer/files/playtest.json" "$tmp/adb.log" && cmp -s "$backup/playtest.json" "$tmp/device/playtest.json" && cmp -s "$backup/throws.csv" "$tmp/device/throws.csv" && [ "$(cat "$backup/SHA256SUMS")" = "$(qr_sha256 "$backup/playtest.json")  playtest.json
$(qr_sha256 "$backup/throws.csv")  throws.csv" ]'
check "playtest.json contents never reach stdout or stderr" '! grep -q "synthetic-private-value\|uploadKey" "$tmp/out" "$tmp/err" && ! grep -rq synthetic-private-value "$root/release-logs"'
check 'the default backup prefix and unchanged data appear in the summary' \
  'grep -Fq "backup:      $backup (verified" "$tmp/out" && grep -Fq "data hash:   configured data files unchanged" "$tmp/out"'
check 'an empty permissions list skips the package query and reports no permissions' \
  'out_has "permissions: none configured" && ! grep -q "dumpsys package" "$tmp/adb.log" && ! out_has RECORD_AUDIO'
reset_logs; FAKE_CORRUPT=1 run install "$apk"
check "a backup copy that differs from the device stops the install" '[ "$rc" != 0 ] && out_has "does not match the device" && [ ! -f "$tmp/installed" ]'

# --- a Quest that drops off adb: wait-for-device, time-boxed by QR_ADB_WAIT.
reset_logs; printf 'offline\ndevice\n' > "$tmp/states"; run install "$apk"
check "install: a Quest that is back on the second get-state installs after one adb wait-for-device" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && [ "$(grep -c "^-s $serial wait-for-device$" "$tmp/adb.log")" = 1 ] && out_has "adb state .offline.: waiting up to 120s"'
reset_logs; printf 'unauthorized\n' > "$tmp/states"; QR_ADB_WAIT=1 run install "$apk"
check "install: a Quest that never comes back fails after the QR_ADB_WAIT time box, installing nothing" \
  '[ "$rc" != 0 ] && [ -f "$tmp/adb-wait.started" ] && [ -f "$tmp/adb-wait.terminated" ] && grep -q "wait-for-device" "$tmp/adb.log" && out_has "waiting up to 1s" && out_has "not connected (adb state .unauthorized.)" && [ ! -f "$tmp/installed" ]'
reset_logs; run install "$apk"
check "install: a connected Quest never waits" '[ "$rc" = 0 ] && ! grep -q wait-for-device "$tmp/adb.log"'
reset_logs; printf 'offline\ndevice\n' > "$tmp/states"; FAKE_LOGCAT="" run launch
check "launch waits for a Quest that dropped off adb too" '[ "$rc" = 0 ] && grep -q "wait-for-device" "$tmp/adb.log" && grep -q "am start" "$tmp/adb.log"'

# Reload the real config reader for mutations after the cached default cases.
. "$QR_DIR/quest-release/config.sh"
unset -f jq
jq 'del(.quest.launcherChecks) | .quest.backupPrefix = "Synthetic_Backup-"' "$YETIKIT_CONFIG" > "$tmp/override.json"
YETIKIT_CONFIG="$tmp/override.json"
reset_logs; run install "$apk"
backup="$HOME/Synthetic_Backup-$(qr_timestamp)"
check 'the configured prefix replaces the default while keeping the timestamp and verified backup' \
  '[ "$rc" = 0 ] && [ -s "$backup/SHA256SUMS" ] && grep -Fq "backup:      $backup (verified" "$tmp/out"'
check 'omitting launcherChecks also skips the package query' \
  'out_has "permissions: none configured" && ! grep -q "dumpsys package" "$tmp/adb.log" && ! out_has RECORD_AUDIO'
jq '.quest.launcherChecks.permissions = ["android.permission.CAMERA", "android.permission.BLUETOOTH_CONNECT", "android.permission.VIBRATE"]' \
  "$YETIKIT_CONFIG" > "$tmp/permissions.json"
YETIKIT_CONFIG="$tmp/permissions.json"
reset_logs; run install "$apk"
check 'install reports only configured permissions with exact names and their distinct states' \
  '[ "$rc" = 0 ] && [ "$(grep -c "dumpsys package" "$tmp/adb.log")" = 1 ] &&
    grep -Fxq "permissions: android.permission.CAMERA granted=false; android.permission.BLUETOOTH_CONNECT granted=true; android.permission.VIBRATE not requested" "$tmp/out" &&
    ! out_has RECORD_AUDIO'
reset_logs; FAKE_PACKAGE_RC=1 run install "$apk"
check 'a failed permission probe is unavailable, not a failed install or an absent permission' \
  '[ "$rc" = 0 ] && out_has "android.permission.CAMERA unavailable" && ! out_has "not requested"'

qr_flow_finish
