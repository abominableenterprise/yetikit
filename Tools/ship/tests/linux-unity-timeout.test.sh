#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Default editor limits: pure passes use 1800 s, Gfx passes use 3600 s.
# Fake editor and logging timeout only; checks are eval'd when they run.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-timeout-fixture.sh"

run bash "$script" test editmode
check "test editmode: the pure pass keeps 1800 s" '[ "$rc" = 0 ] && [ "$(limit editmode.xml)" = 1800 ]'
check "test editmode: the Gfx pass gets 3600 s by default" '[ "$(limit editmode-gfx.xml)" = 3600 ]'
check "test editmode: the Gfx pass logs its timeout" 'grep -q "editmode-gfx: Gfx pass, timeout 3600 s" "$tmp/err"'
run bash "$script" test editmode -testCategory Gfx
check "test editmode -testCategory Gfx: one pass at 3600 s" '[ "$(cat "$tmp/limits")" = "3600 editmode.xml" ]'
run bash "$script" test editmode -testCategory "Gfx;Other"
check "test editmode -testCategory Gfx;Other: still the Gfx timeout" '[ "$(limit editmode.xml)" = 3600 ]'
run bash "$script" test editmode -testCategory MacOnly
check "test editmode -testCategory MacOnly: the plain 1800 s" '[ "$(limit editmode.xml)" = 1800 ]'
run bash "$script" test editmode -testCategory "!Gfx"
check "test editmode -testCategory !Gfx: the plain 1800 s" '[ "$(limit editmode.xml)" = 1800 ]'
run bash "$script" test pr
check "test pr: pure pass 1800 s, Gfx pass 3600 s" \
  '[ "$rc" = 0 ] && [ "$(limit editmode.xml)" = 1800 ] && [ "$(limit editmode-gfx.xml)" = 3600 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
