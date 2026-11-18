#!/usr/bin/env bash
# Fake adb only. The short deadline exercises the real timebox.
# shellcheck disable=SC2016 # check evaluates conditions in the shared fixture.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"
qr_flow_keystore
mkdir -p "$tmp/sdk/build-tools/34.0.0"
printf '#!/bin/sh\necho 0.9\n' > "$tmp/sdk/build-tools/34.0.0/apksigner"
printf '#!/bin/sh\nexit 99\n' > "$tmp/not-an-editor"
chmod +x "$tmp/sdk/build-tools/34.0.0/apksigner" "$tmp/not-an-editor"
export UNITY_BIN="$tmp/not-an-editor" QR_DEVICE_CHECK_WAIT=2
qr_test_no_gtimeout
adb() {
  printf '%s\n' "$*" >> "$tmp/adb.log"
  if [ "$1" = devices ]; then
    printf 'List of devices attached\n%s\toffline\n' "$serial"
    return 0
  fi
  [ "$1" = -s ] && [ "$2" = "$serial" ] || return 99
  shift 2
  case "$1" in
    get-state)
      case "$scenario" in
        unauthorized) echo 'error: device unauthorized' >&2; return 1 ;;
        wrong-maker) echo device ;;
        recover|discover)
          if [ -f "$tmp/waited" ]; then echo device
          else echo 'error: device offline' >&2; return 1; fi ;;
        hang)
          if [ -f "$tmp/waited" ]; then qr_test_block_until_term "$tmp/state"
          else echo 'error: device offline' >&2; return 1; fi ;;
        persist) echo "error: device '$serial' not found" >&2; return 1 ;;
        *) return 99 ;;
      esac ;;
    reconnect) touch "$tmp/reconnected" ;;
    wait-for-device)
      if [ "$scenario" = persist ]; then qr_test_block_until_term "$tmp/wait"
      elif [ -f "$tmp/reconnected" ]; then touch "$tmp/waited"
      else return 99; fi ;;
    shell) shift; fake_shell "$*" ;;
    *) return 99 ;;
  esac
}
count() { grep -Fxc -- "-s $serial $1" "$tmp/adb.log"; }
check_recovered() {
  [ "$rc" = 0 ] && grep -q '^ok .*device .*manufacturer Oculus' "$tmp/out" &&
    [ "$(count reconnect)" = 1 ] && [ "$(count wait-for-device)" = 1 ] && [ "$(count get-state)" = 2 ] &&
    [ ! -e "$root/release-logs" ]
}
device_lock="/tmp/yetikit-quest-device-locks-$UID/$(printf '%s' "$serial" | qr_sha256).lock"
scenario=recover run doctor
check 'doctor reconnects only the selected serial and validates it after the wait' 'check_recovered'
rm -f "$tmp/waited" "$tmp/reconnected" "$tmp/adb.log"
QUEST_SERIAL='' scenario=discover run doctor
check 'doctor can recover the sole discovered headset without choosing another' \
  'check_recovered && [ "$(grep -c "^devices$" "$tmp/adb.log")" = 1 ]'
rm -f "$tmp/waited" "$tmp/reconnected" "$tmp/adb.log"
scenario=persist run doctor
check 'persistent absence times out, releases the device lock and skips the idle probe' \
  '[ "$rc" = 1 ] && grep -q "^FAIL .*device .*timed out after 2s" "$tmp/out" && [ "$(count wait-for-device)" = 1 ] && [ -e "$tmp/wait.terminated" ] && ! grep -q dumpsys "$tmp/adb.log" && [ ! -e "$device_lock" ]'
rm -f "$tmp/waited" "$tmp/reconnected" "$tmp/adb.log"
scenario=hang run doctor
check 'the final probe shares the reconnect deadline and is terminated if it hangs' \
  '[ "$rc" = 1 ] && grep -q "^FAIL .*device .*timed out after 2s" "$tmp/out" && [ "$(count get-state)" = 2 ] && [ -e "$tmp/state.terminated" ]'
rm -f "$tmp/waited" "$tmp/reconnected" "$tmp/adb.log"
mkdir "$device_lock" || exit 1
printf '%s\n' "$$" > "$device_lock/pid"
scenario=recover run doctor
rm -rf "$device_lock"
check 'doctor never reconnects a transport reserved by a concurrent release' \
  '[ "$rc" = 1 ] && grep -q "reconnect unavailable" "$tmp/out" && [ "$(count get-state)" = 1 ] && ! grep -Eq " reconnect| wait-for-device" "$tmp/adb.log"'
for scenario in unauthorized wrong-maker; do
  rm -f "$tmp/adb.log"
  if [ "$scenario" = wrong-maker ]; then FAKE_MAKER=other run doctor; else run doctor; fi
  check "$scenario fails doctor without retry" \
    '[ "$rc" = 1 ] && grep -q "^FAIL .*device " "$tmp/out" && [ "$(count get-state)" = 1 ] && ! grep -Eq " reconnect| wait-for-device|dumpsys" "$tmp/adb.log"'
done
qr_flow_finish
