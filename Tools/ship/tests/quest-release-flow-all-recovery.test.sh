#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_keystore
qr_flow_healthy_log

# One unlisted failure: its one rerun passes, so all installs.
xml_one='<?xml version="1.0"?><test-run id="2" total="3" passed="2" failed="1" skipped="0"><test-suite type="TestFixture" fullname="Ns.A" result="Failed" site="Child"><test-case fullname="Ns.A.One" result="Passed"/><test-case fullname="Ns.A.New" result="Failed"><failure><message>new flake</message></failure></test-case></test-suite></test-run>'
for k in test build; do [ -d "$root/rel-$short-$k" ] && git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done
# The retry must actually pass the selected Ns.A.New case, not the unrelated Ns.A.One from the generic fixture.
reset_logs; FAKE_XML="$xml_one" FAKE_RETRY_XML="${xml_pass/Ns.A.One/Ns.A.New}" run all
check "all: one unlisted gate failure that passes on its rerun installs" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && grep -q -- "-testFilter Ns.A.New " "$tmp/unity.log" && grep -q "retried 1 unlisted failure: Ns.A.New, passed on rerun" "$tmp/out"'
reset_logs; FAKE_XML="$xml_fail" run all
# The operator's manual rerun in the same run folder: the summary shows each step's latest result.
reset_logs; run gate
check "after a failed all, a passing gate rerun clears 'install: skipped: gate failed'" \
  '[ "$rc" = 0 ] && ! grep -q "gate failed" "$tmp/out" && grep -q "install:     not run yet (gate ok)" "$tmp/out"'
reset_logs; run install; run launch
check "after a failed all, then gate, install, launch: the summary says install ok and the launch" \
  '[ "$rc" = 0 ] && grep -q "^install:     install ok ($apk)" "$tmp/out" && grep -q "^launch:      fps 71.9" "$tmp/out" && grep -q "^gate:        Gfx;MacOnly: 3 tests, 3 passed" "$tmp/out" && ! grep -q "^install: .*skipped\|gate failure" "$tmp/out"'
reset_logs; FAKE_MAKER=samsung run install "$apk"
check "a refused install replaces the stale 'not run yet' with its own result" \
  '[ "$rc" != 0 ] && grep -q "^install:     install stopped before adb install" "$tmp/out"'
for k in test build; do git -C "$repo" worktree remove --force "$root/rel-$short-$k"; done

qr_flow_finish
