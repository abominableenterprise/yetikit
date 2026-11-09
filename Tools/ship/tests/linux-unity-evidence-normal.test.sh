#!/usr/bin/env bash
# Synthetic editor regressions: evidence normal.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

FAKE_XML_MODE=zero run editmode
check "unfiltered pure pass still cannot be empty" '[ "$rc" != 0 ]'
EDITMODE_GFX=0 run editmode -testFilter PureClass
check "disabling Gfx still runs just the filtered pure pass" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
FAKE_XML_MODE=zero EDITMODE_GFX=0 run editmode -testFilter PureClass
check "disabling Gfx still requires executed pure tests" '[ "$rc" != 0 ]'
FAKE_XML_MODE=zero run playmode
check "PlayMode must execute tests" '[ "$rc" != 0 ]'
FAKE_FAILS=X.Tests.Broken EDITMODE_GFX=0 run editmode
check "a real test failure retains editor exit 2" '[ "$rc" = 2 ]'
run editmode
check "normal EditMode still passes with both XML totals" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode.xml:.*total=\"1\"" "$tmp/err" && grep -q "editmode-gfx.xml:.*passed=\"1\"" "$tmp/err"'
run playmode
check "normal PlayMode still passes" '[ "$rc" = 0 ]'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
