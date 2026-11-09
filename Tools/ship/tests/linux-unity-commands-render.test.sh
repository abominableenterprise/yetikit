#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# RenderTool filter routing and mixed-filter rejection with a fake editor.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-render.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

good_ulf > "$ULF"

# --- #120: a filter-only run of a RenderTool class goes through the single Xvfb pass --------------------------------
printf 'namespace ExampleGame.Park.Tests {\n  [Category("RenderTool")]\n  public class CourtStripCapture {}\n}\n' > "$proj/Assets/Tests/Park/CourtStripCapture.cs"
printf 'namespace X {\n  [Category("Gfx")]\n  public class Other {}\n}\n' > "$proj/Assets/Tests/Park/Other.cs"
runs() { : > "$tmp/runs"; EDITMODE_GFX=1 lu test editmode "$@"; }
for f in ExampleGame.Park.Tests.CourtStripCapture CourtStripCapture ExampleGame.Park.Tests.CourtStripCapture.RenderTheDribbleStrips; do
  check "test -testFilter $f: one pass, on Xvfb, -testCategory RenderTool, no -nographics" \
    'runs -testFilter "$f" && [ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q -- "-testCategory RenderTool" "$tmp/runs" && ! grep -q -- -nographics "$tmp/runs" && grep -q "RenderTool class CourtStripCapture" "$tmp/err"'
done
check "test -testFilter <other class>: still the two category passes" \
  'runs -testFilter X.Other && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q -- "-nographics.*!Gfx;!MacOnly" "$tmp/runs" && ! grep -q RenderTool "$tmp/runs"'
check "test -testFilter CourtStripCaptureX (a longer name) is not a RenderTool run" \
  'runs -testFilter CourtStripCaptureX && [ "$(wc -l < "$tmp/runs")" = 2 ]'
check "test -testFilter mixing a RenderTool class with other tests is rejected before any editor run" \
  '! runs -testFilter "X.Other;ExampleGame.Park.Tests.CourtStripCapture" && grep -q "run the render tool on its own" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "test -testCategory RenderTool -testFilter ...: the documented command is unchanged (one pass)" \
  'runs -testCategory RenderTool -testFilter CourtStripCapture && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ "$(grep -o -- -testCategory "$tmp/runs" | wc -l)" = 1 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
