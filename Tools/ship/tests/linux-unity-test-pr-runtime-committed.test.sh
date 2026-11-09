#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: committed runtime references and base selection.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

pr_changed_test_fixture

# --- runtime changes: whole-word references in the matching area only -------------------------------------------------
echo '// tweak' >> "$proj/Assets/Scripts/Props/Spray/Spray.cs"
pr HEAD
check "a runtime class selects only the one Gfx fixture whose source mentions that class" \
  '[ "$rc" = 0 ] && [ "$(filter)" = ExampleGame.Props.Tests.SprayTests ]'
check "runtime selection logs the reference and source" \
  'grep -q "why: references Spray from Assets/Scripts/Props/Spray/Spray.cs" "$tmp/err"'
check "pure fixtures, nested classes and substring-only references are excluded" '! filter | grep -qE "RulesTests|Inner|ThrowTests"'
commit spray
pr
check "changed tests and referencing runtime fixtures are unioned and sorted" \
  '[ "$(filter)" = "ExampleGame.Props.Tests.SprayTests;ExampleGame.Props.Tests.ThrowTests" ]'
pr HEAD
check "test pr HEAD: nothing changed, Gfx pass skipped" '[ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q "no Gfx fixtures touched" "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
