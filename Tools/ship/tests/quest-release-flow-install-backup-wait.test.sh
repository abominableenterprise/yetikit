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
check "the summary reports the backup, playtest.json unchanged and RECORD_AUDIO granted" \
  'grep -q "backup:      $backup (verified" "$tmp/out" && grep -q "data hash:   configured data files unchanged" "$tmp/out" && grep -q "mic:         RECORD_AUDIO granted=true" "$tmp/out"'
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


qr_flow_finish
