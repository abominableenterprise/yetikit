#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: selection budgets and unchanged editmode behavior.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

pr_changed_test_fixture

# --- upfront estimate and count-scaled budget (no editor) ------------------------------------------------------------
(
  . "$(dirname "$script")/test-passes.sh"
  log() { printf '%s\n' "$*"; }
  many="$(for i in $(seq 46); do echo "X.Fixture$i"; done)"
  UNITY_GFX_TIMEOUT=3600 TEST_PR_TIMEOUT_EXPLICIT= pr_gfx_budget "$many" > "$tmp/budget"
  grep -q 'selected 46 Gfx fixtures; estimated tests 4140 s.*timeout 6720 s' "$tmp/budget"
) && budget_ok=1 || budget_ok=0
check "46 selected fixtures scale the default budget beyond startup plus the observed 60-minute test time" '[ "$budget_ok" = 1 ]'
(
  . "$(dirname "$script")/test-passes.sh"
  log() { printf '%s\n' "$*"; }
  UNITY_GFX_TIMEOUT=77 TEST_PR_TIMEOUT_EXPLICIT=77 pr_gfx_budget X.Fixture > "$tmp/budget"
  grep -q 'selected 1 Gfx fixtures; estimated tests 90 s.*timeout 77 s' "$tmp/budget"
) && budget_ok=1 || budget_ok=0
check "explicit caller timeout still wins over the scaled default" '[ "$budget_ok" = 1 ]'
pr
check "test pr prints selection size and estimate before pure starts" \
  'awk "/selected [0-9]+ Gfx fixtures; estimated tests/ { estimate=NR } /stage pure-pass start/ { exit !(estimate && estimate < NR) }" "$tmp/err"'

# --- test editmode is unchanged ---------------------------------------------------------------------------------------
: > "$tmp/runs"; bash "$script" test editmode 2>"$tmp/err"
check "test editmode still runs full Gfx (no -testFilter)" \
  '[ "$(wc -l < "$tmp/runs")" = 2 ] && gfx_run | grep -q -- "-testCategory Gfx" && ! grep -q -- -testFilter "$tmp/runs"'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
