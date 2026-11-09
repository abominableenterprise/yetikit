#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: nested and deleted editor builders.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"

pr_explicit_roots_fixture

# Editor roots may sit inside the scripts root: builder references must still
# search all tests, not an inferred Editor area (which is absent here).
mv "$proj/Assets/_Project/Editor" "$proj/Assets/_Project/Scripts/Editor"
jq '.tests.editorRoot = "Assets/_Project/Scripts/Editor"' "$proj/yetikit.json" > "$tmp/config.json"
mv "$tmp/config.json" "$proj/yetikit.json"
commit nested-editor-layout
echo '// changed nested builder' >> "$proj/Assets/_Project/Scripts/Editor/World/Court/CourtBuilder.cs"
pick
check "nested editor root takes precedence over scripts-area selection" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Park.Tests.HoopTests ] && grep -q "why: references builder CourtBuilder" "$tmp/pick-err"'
rm "$proj/Assets/_Project/Scripts/Editor/World/Court/CourtBuilder.cs"
pick
check "deleted nested editor builder still searches fixtures outside the inferred area" \
  '[ "$(< "$tmp/picked")" = ExampleGame.Park.Tests.HoopTests ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
