#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Synthetic PR-selection regressions: unchanged and changed test classes.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-test-pr-fixture.sh"


# --- nothing touched and changed test classes -------------------------------------------------------------------------
git -C "$proj" checkout -q -b feature
echo more >> "$proj/README.md"; commit docs
pr
check "no Gfx fixture touched: only the pure pass runs" '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
check "the pure pass is full (-nographics, !Gfx;!MacOnly, no -testFilter)" \
  'pure_run | grep -q -- "-nographics -runTests -testPlatform EditMode -testCategory !Gfx;!MacOnly" && ! pure_run | grep -q -- -testFilter'
check "it logs no Gfx fixtures touched" 'grep -q "no Gfx fixtures touched" "$tmp/err"'
check "pure results are in editmode.xml" 'grep -q "<test-run" "$OUT_DIR/editmode.xml" && [ ! -f "$OUT_DIR/editmode-gfx.xml" ]'
echo '// tweak' >> "$t/Props/ThrowTests.cs"; commit throw
pr
check "a changed Gfx test file gets a second pass, with only its declared fixture" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && [ "$(filter)" = ExampleGame.Props.Tests.ThrowTests ]'
check "the Gfx pass uses Xvfb and the Gfx category" '! gfx_run | grep -q -- -nographics && gfx_run | grep -q -- "-testCategory Gfx"'
check "stderr explains the changed-test selection" \
  'grep -q "selected ExampleGame.Props.Tests.ThrowTests" "$tmp/err" && grep -q "why: changed test Assets/Tests/EditMode/Props/ThrowTests.cs" "$tmp/err"'
check "Gfx results are in editmode-gfx.xml" 'grep -q ThrowTests "$OUT_DIR/editmode-gfx.xml"'
# Multiple declarations in one changed source; a non-Gfx class is excluded.
printf '\nnamespace ExampleGame.Props.Tests\n{\n    [Category("Gfx")]\n    public class ExtraTests { }\n    public class PureExtraTests { }\n}\n' >> "$t/Props/ThrowTests.cs"
pr HEAD
check "a changed test file selects every Gfx class declared there, not the whole folder" \
  '[ "$(filter)" = "ExampleGame.Props.Tests.ExtraTests;ExampleGame.Props.Tests.ThrowTests" ]'
git -C "$proj" checkout -q -- Assets/Tests/EditMode/Props/ThrowTests.cs


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
