#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Explicit caller limits override defaults.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-timeout-fixture.sh"
run UNITY_TIMEOUT=5400 bash "$script" test editmode
check "an explicit UNITY_TIMEOUT sets both passes" '[ "$(limit editmode.xml)" = 5400 ] && [ "$(limit editmode-gfx.xml)" = 5400 ]'
run UNITY_TIMEOUT=900 bash "$script" test pr
check "an explicit UNITY_TIMEOUT (lower) also wins for test pr's Gfx pass" '[ "$(limit editmode-gfx.xml)" = 900 ]'
run UNITY_GFX_TIMEOUT=7200 bash "$script" test editmode
check "UNITY_GFX_TIMEOUT sets only the Gfx pass" '[ "$(limit editmode.xml)" = 1800 ] && [ "$(limit editmode-gfx.xml)" = 7200 ]'
run UNITY_TIMEOUT=600 UNITY_GFX_TIMEOUT=7200 bash "$script" test editmode
check "both set: each pass gets its own" '[ "$(limit editmode.xml)" = 600 ] && [ "$(limit editmode-gfx.xml)" = 7200 ]'
run bash "$script" open
check "open keeps UNITY_TIMEOUT's 1800 s" '[ "$(cat "$tmp/limits")" = "1800 " ]'
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
