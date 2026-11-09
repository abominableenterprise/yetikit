#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build
qr_flow_healthy_log

reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
10-31 12:00:40.000  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main" run launch
check "a FATAL line is a crash (exit 1)" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
for unrelated in \
  '10-31 12:00:40.000  9999  9999 E AndroidRuntime: FATAL EXCEPTION: main' \
  'E/AndroidRuntime( 9999): FATAL EXCEPTION: main' \
  '10-31 12:00:40.000  9999  9999 F libc: Fatal signal 11 in tid 9999' \
  "10-31 12:00:40.000  9999  9999 F DEBUG: pid: 8888, tid: 8888, name: other >>> $QR_PKG.other <<<"; do
  reset_logs; FAKE_LOGCAT="$FAKE_LOGCAT
$unrelated" run launch
  check "unrelated crash remains diagnostic, not a launch failure: $unrelated" \
    '[ "$rc" = 0 ] && ! grep -q "launch:      CRASH" "$tmp/out"'
done
reset_logs; FAKE_LOGCAT='E/AndroidRuntime( 4242): FATAL EXCEPTION: main' run launch
check "brief-format game crash is scoped by PID" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_LOGCAT="10-31 12:00:40.000  9999  9999 F DEBUG: pid: 4242, tid: 4242, name: UnityMain >>> $QR_PKG <<<" run launch
check "native tombstone for the exact game package fails launch" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_LOGCAT="10-31 12:00:40.000  9998  9998 E AndroidRuntime: FATAL EXCEPTION: main
10-31 12:00:40.001  9998  9998 E AndroidRuntime: Process: $QR_PKG, PID: 9998" run launch
check "package attribution catches a game process that restarted during observation" '[ "$rc" != 0 ] && grep -q "launch:      CRASH" "$tmp/out"'
reset_logs; FAKE_ALIVE=0 run launch
check "a dead process is a crash" '[ "$rc" != 0 ] && grep -q "alive no" "$tmp/out"'

qr_flow_finish
