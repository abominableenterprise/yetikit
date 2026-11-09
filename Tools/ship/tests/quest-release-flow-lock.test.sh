#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build
qr_flow_old_apk

# --- single-run lock: all, prepare, gate, build, verify, install, launch, rollback, cleanup (kill -0 on the recorded PID, never pgrep -f) -----------
lock="$root/release-logs/run.lock"
for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
reset_logs; run prepare; reset_logs; run gate
check "gate holds the lock (its PID and run folder) while Unity runs and releases it on exit" \
  '[ "$rc" = 0 ] && grep -q "^lock pid=[0-9][0-9]* run=$root/release-logs/$short-" "$tmp/unity-lock.log" && [ ! -e "$lock" ]'
qr_test_block_until_term "$tmp/live-lock" >/dev/null 2>&1 & live=$!
qr_fixture_wait_ready "$tmp/live-lock.started" "$live" || exit 1
mkdir -p "$lock"; echo "$live" > "$lock/pid"; echo "$tmp/other-run" > "$lock/run_dir"
reset_logs; rm -f "$tmp/git.log"; run all
check "a second all refuses at once while a live run holds the lock, naming its PID and run folder" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active (pid $live, run folder $tmp/other-run)" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/git.log" ] && [ "$(cat "$lock/pid")" = "$live" ]'
for cmd in prepare gate build "install $apk" "rollback $old"; do
  # shellcheck disable=SC2086 # cmd is a step and its argument
  reset_logs; run $cmd
  check "${cmd%% *} refuses while the lock is live, touching neither Unity nor the device" \
    '[ "$rc" != 0 ] && out_has "another quest-release run is active" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/installed" ] && [ -d "$lock" ]'
done
reset_logs; run cleanup
check "cleanup refuses while the lock is live and keeps the live run's worktrees (nightly prepare && gate; cleanup)" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active" && [ -d "$root/rel-$short-test" ] && [ -d "$root/rel-$short-build" ] && [ -d "$lock" ]'
live_run="$(sed -n 's/^QR_RUN_DIR=//p' "$root/release-logs/current.env")"
echo live-apk > "$live_run/summary/apk"
reset_logs; run verify "$apk"
check "verify refuses while the lock is live and leaves the live run's apk fields alone" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active" && [ ! -f "$tmp/py.log" ] && [ "$(cat "$live_run/summary/apk")" = live-apk ] && [ "$(cat "$lock/pid")" = "$live" ]'
reset_logs; run launch
check "launch refuses while the lock is live: no logcat -c, no am start" \
  '[ "$rc" != 0 ] && out_has "another quest-release run is active" && ! grep -q "logcat\|am start" "$tmp/adb.log" 2>/dev/null && [ -d "$lock" ]'
reset_logs; run summary
check "summary takes no lock" '[ "$rc" = 0 ] && ! out_has "another quest-release run"'
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
reset_logs; run gate
check "a stale lock (PID gone) is removed with a log line and the run goes ahead" \
  '[ "$rc" = 0 ] && out_has "removing a stale lock $lock (pid $live is gone" && [ -f "$tmp/unity.log" ] && [ ! -e "$lock" ]'
check "the release scripts never search processes by command line (pgrep / pkill)" \
  '! grep -rnE "p(grep|kill)" "$script" "$(dirname "$script")/quest-release"'


qr_flow_finish
