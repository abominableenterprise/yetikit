#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_keystore
qr_flow_healthy_log
qr_flow_notes

reset_logs; run all --notes "$notes"
check "all --notes hands YETIKIT_WHATS_NEW to the build only" \
  '[ "$(grep -c "^notes=$notes " "$tmp/notes-env.log")" = 2 ] && grep -q "^-s $serial install -r $apk$" "$tmp/adb.log"'
check "all: the happy path verifies, installs, launches and cleans up" \
  '[ "$rc" = 0 ] && [ "$(cat "$tmp/installed")" = "$apk" ] && grep -q "logcat -d" "$tmp/adb.log" && [ ! -d "$root/rel-$short-test" ] && [ ! -d "$root/rel-$short-build" ]'
check "all: the keystore preflight runs once, not again in build" '[ "$(grep -c . "$tmp/keytool.log")" = 1 ]'
check "all: the summary block has every field" \
  'for f in commit: gate: "gate fails:" apk: "apk sha256:" cert: "idle check:" backup: install: "data hash:" mic: launch:; do grep -q "^$f" "$tmp/out" || exit 1; done'

qr_flow_finish
