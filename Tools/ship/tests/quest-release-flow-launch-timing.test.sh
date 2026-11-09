#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build
qr_flow_healthy_log

# Exercise the default 60 s path without waiting: an early-only broadcast may
# roll out of the final snapshot. Stub only launch observation, not timeboxes.
launch_timing() (
  local dumps=0
  sleep() {
    if [ "${FUNCNAME[1]:-}" = qr_launch_locked ]; then
      echo "$1" >> "$tmp/launch-sleeps"
    else
      command sleep "$@"
    fi
  }
  qr_adb() {
    if [ "${1:-}" = logcat ] && [ "${2:-}" = -d ]; then
      dumps=$((dumps + 1))
      echo "snapshot $dumps" >> "$tmp/launch-snapshots"
      if [ "$dumps" = 1 ] && [ "$QR_LAUNCH_WAIT" -gt 30 ]; then
        [ "${FAKE_EARLY_FAIL:-0}" = 0 ] || { echo 'adb unavailable'; return 1; }
        printf '%s\n' "$FAKE_LOGCAT"
        echo '11-01 12:00:30.000 I VrShell: appLaunchFailureBroadcastReceived packageName=com.example.consumer'
      else
        printf '%s\n' "$FAKE_LOGCAT"
      fi
    else
      adb -s "$serial" "$@"
    fi
  }
  qr_main launch
)
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=60 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "default wait checks at 30 s, then at 60 s, preserving early-only warnings" \
  '[ "$rc" = 0 ] && [ "$(paste -sd, "$tmp/launch-sleeps")" = 30,30 ] && [ "$(wc -l < "$tmp/launch-snapshots")" = 2 ] && out_has "30s check" && out_has "shell launch warnings 1"'
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=60 FAKE_EARLY_FAIL=1 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "early snapshot failure is infrastructure, not a crash" \
  '[ "$rc" = 3 ] && out_has "early adb logcat -d failed" && [ "$(wc -l < "$tmp/launch-snapshots")" = 1 ] && out_has "launch:      INFRA:"'
rm -f "$tmp/launch-sleeps" "$tmp/launch-snapshots"
rc=0; QR_LAUNCH_WAIT=30 launch_timing > "$tmp/out" 2> "$tmp/err" || rc=$?
check "a 30 s wait uses one final snapshot without an additional delay" \
  '[ "$rc" = 0 ] && [ "$(paste -sd, "$tmp/launch-sleeps")" = 30 ] && [ "$(wc -l < "$tmp/launch-snapshots")" = 1 ]'

qr_flow_finish
