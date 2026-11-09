#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_keystore
qr_flow_old_apk

reset_logs; FAKE_LOGCAT='10-31 12:00:40.000  9999  9999 E AndroidRuntime: FATAL EXCEPTION: main' run all --rollback "$old"
check "all does not roll back a healthy release for another app crash" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/installed")" = 1 ] && ! grep -q "install -r -d" "$tmp/adb.log"'
reset_logs; FAKE_ALIVE=0 run all --rollback "$old"
check "all --rollback: a crash at launch rolls back to the given APK" \
  '[ "$rc" != 0 ] && [ "$(sed -n 2p "$tmp/installed")" = "$old" ]'
for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
reset_logs; FAKE_KEYSTORE_CERT="AA:BB" run all
check "all: a wrong debug keystore stops before the gate and build, installs nothing" \
  '[ "$rc" != 0 ] && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/installed" ] && out_has "$HOME/.android/debug.keystore" && grep -q "apk:         not built" "$tmp/out"'


qr_flow_finish
