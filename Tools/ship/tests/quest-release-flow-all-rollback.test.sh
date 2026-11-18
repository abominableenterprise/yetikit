#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_keystore
qr_flow_old_apk

reset_logs; FAKE_LOGCAT='10-31 12:00:40.000  9999  9999 E AndroidRuntime: FATAL EXCEPTION: main' run all --rollback "$old"
check "all does not roll back a healthy release for another app crash" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/installed")" = 1 ] && ! grep -q "install -r -d" "$tmp/adb.log"'
reset_logs; FAKE_ALIVE=0 FAKE_LOGCAT="10-31 12:00:40.000 4242 4242 E AndroidRuntime: FATAL EXCEPTION: main
10-31 12:00:40.001 4242 4242 E AndroidRuntime: Process: $QR_PKG, PID: 4242" run all --rollback "$old"
check "all --rollback: a crash at launch rolls back to the given APK" \
  '[ "$rc" = 1 ] && grep -q "install -r -d .*${old##*/}$" "$tmp/adb.log"'

# Trace real lock boundaries and the bytes adb receives, including a same-ref
# rebuild whose output path is also the requested rollback input.
eval "$(declare -f qr_lock_acquire | sed '1s/qr_lock_acquire/fixture_lock_acquire/')"
qr_lock_acquire() {
  fixture_lock_acquire "$@" || return
  case "$(qr_lock_dir)" in */yetikit-quest-device-locks-*/*) echo lock >> "$tmp/transaction" ;; esac
}
eval "$(declare -f qr_lock_release | sed '1s/qr_lock_release/fixture_lock_release/')"
qr_lock_release() {
  case "$(qr_lock_dir)" in */yetikit-quest-device-locks-*/*) echo unlock >> "$tmp/transaction" ;; esac
  fixture_lock_release
}
eval "$(declare -f adb | sed '1s/adb/fixture_adb/')"
adb() {
  case "$3" in
    install)
      echo install >> "$tmp/transaction"
      if [ "$5" = -d ]; then cp "${@: -1}" "$tmp/rollback-bytes"
      else cp "${@: -1}" "$tmp/primary-bytes"; fi ;;
    shell) case "$4" in 'am start '*) echo launch >> "$tmp/transaction" ;; esac ;;
  esac
  fixture_adb "$@"
}
cp "$old" "$apk"
reset_logs; FAKE_ALIVE=0 FAKE_LOGCAT="10-31 12:00:40.000 4242 4242 E AndroidRuntime: Process: $QR_PKG, PID: 4242" \
  run all --rollback "$apk"
check 'single-device all locks once across install, launch and crash rollback' \
  '[ "$rc" = 1 ] && [ "$(cat "$tmp/transaction")" = "$(printf "lock\ninstall\nlaunch\ninstall\nunlock")" ]'
check 'same-ref crash rollback installs the pre-build bytes, not the freshly retained APK' \
  '[ -s "$tmp/primary-bytes" ] && ! cmp -s "$old" "$tmp/primary-bytes" && cmp -s "$old" "$tmp/rollback-bytes"'

for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
reset_logs; FAKE_KEYSTORE_CERT="AA:BB" run all
check "all: a wrong debug keystore stops before the gate and build, installs nothing" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/installed" ] && out_has "$HOME/.android/debug.keystore" && grep -q "apk:         not built" "$tmp/out"'


qr_flow_finish
