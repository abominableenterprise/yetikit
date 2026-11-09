#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: options and failure propagation.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

pr_changed_test_fixture

# --- options and failures ---------------------------------------------------------------------------------------------
pr -logLevel x
check "extra Unity args go to both passes; base stays origin/main" \
  '[ "$(wc -l < "$tmp/runs")" = 2 ] && pure_run | grep -q -- "-logLevel x" && gfx_run | grep -q -- "-logLevel x"'
pr -testFilter Foo
check "test pr with -testFilter is refused before any editor run" '[ "$rc" != 0 ] && [ ! -s "$tmp/runs" ] && grep -q "use test editmode" "$tmp/err"'
pr no-such-ref
check "unknown base fails clearly" '[ "$rc" != 0 ] && grep -q "no merge-base between no-such-ref and HEAD" "$tmp/err"'
: > "$tmp/runs"; rc=0; FAKE_FAILS=ExampleGame.Props.Tests.RulesTests.A bash "$script" test pr 2>"$tmp/err" || rc=$?
check "pure-pass failure still runs Gfx and fails the run" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ]'
: > "$tmp/runs"; rc=0; EDITMODE_GFX=0 bash "$script" test pr 2>"$tmp/err" || rc=$?
check "EDITMODE_GFX=0 skips Gfx" '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
