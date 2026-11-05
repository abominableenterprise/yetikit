#!/usr/bin/env bash
# Tests the known-flakes retry of `linux-unity.sh test`: when every failed test of a pass is in known-flakes.txt, those
# rerun once (-testFilter, <pass>-retry.xml) and a green rerun passes; any other failure still fails. Fake editor.
# Run: bash Tools/ship/tests/linux-unity-flakes.test.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"; mkdir -p "$proj"
. "$(dirname "$0")/lib/fake-unity.sh"

flakes="$tmp/flakes.txt"
cat > "$flakes" <<'EOF'
# a comment line
X.Tests.Court.TheBallersKeepPlaying   # a trailing comment
  X.Tests.Throw.AFlick
X.Tests.Seam
EOF
export KNOWN_FLAKES="$flakes"
ballers=X.Tests.Court.TheBallersKeepPlaying
flick1='X.Tests.Throw.AFlick(False,25f)'; flick2='X.Tests.Throw.AFlick(True,25f)'
run() { : > "$tmp/runs"; rc=0; bash "$script" test "$@" 2>"$tmp/err" || rc=$?; }
retry_filter() { grep -- -retry.xml "$tmp/runs" | sed -n 's/.*-testFilter \([^ ]*\).*/\1/p'; }

# --- only known flakes failed, and they pass on the rerun ----------------------------------------------------------------
FAKE_FAILS="$ballers;$flick1;$flick2" EDITMODE_GFX=0 run editmode
check "only known flakes failed, green rerun: exit 0" '[ "$rc" = 0 ]'
check "it prints flaky-passed with the names" \
  'grep -qF "[linux-unity] flaky-passed: $ballers $flick1 $flick2" "$tmp/err"'
check "the rerun is one more editor run, the same pass, with a -testFilter of just the flakes (cases as their method)" \
  '[ "$(wc -l < "$tmp/runs")" = 2 ] && [ "$(retry_filter)" = "$ballers;X.Tests.Throw.AFlick" ] && grep -- -retry.xml "$tmp/runs" | grep -q -- "-nographics.*-testCategory !Gfx;!MacOnly"'
check "both runs' results are kept: editmode.xml (failed) and editmode-retry.xml (passed)" \
  'grep -q "failed=\"3\"" "$OUT_DIR/editmode.xml" && grep -q "failed=\"0\"" "$OUT_DIR/editmode-retry.xml" && [ -f "$OUT_DIR/editmode-retry.log" ]'

FAKE_FAILS=X.Tests.Seam.Padding EDITMODE_GFX=0 run editmode
check "a test of a listed fixture counts as a known flake" '[ "$rc" = 0 ] && grep -q "flaky-passed: X.Tests.Seam.Padding" "$tmp/err"'

FAKE_FAILS="$ballers" EDITMODE_GFX=0 run editmode -testFilter X.Tests -logLevel x
check "the rerun replaces the caller's -testFilter and keeps its other args" \
  '[ "$rc" = 0 ] && [ "$(retry_filter)" = "$ballers" ] && [ "$(grep -- -retry.xml "$tmp/runs" | grep -o -- -testFilter | wc -l)" = 1 ] && grep -- -retry.xml "$tmp/runs" | grep -q -- "-logLevel x"'

# --- real failures still fail --------------------------------------------------------------------------------------------
FAKE_FAILS="$ballers;X.Tests.Real.Broken" EDITMODE_GFX=0 run editmode
check "a failure not in the list: exit nonzero, no rerun" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q "X.Tests.Real.Broken failed and is not a known flake" "$tmp/err" && ! grep -q flaky-passed "$tmp/err"'
FAKE_FAILS=X.Tests.Court.TheBallersKeepPlayingToo EDITMODE_GFX=0 run editmode
check "a longer name sharing a listed prefix is not a known flake" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
FAKE_FAILS="$ballers" FAKE_RETRY_FAILS="$ballers" EDITMODE_GFX=0 run editmode
check "a known flake that fails again: exit nonzero, both XMLs written" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "failed again" "$tmp/err" && grep -q "failed=\"1\"" "$OUT_DIR/editmode-retry.xml" && ! grep -q flaky-passed "$tmp/err"'
FAKE_NO_XML=1 EDITMODE_GFX=0 run editmode
check "a crash with no results XML is never a flake" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
FAKE_FAILS="$ballers" run playmode; FAKE_NO_XML=1 run playmode
check "a crash after an earlier flaky run never reruns the stale XML's flakes" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ ! -f "$OUT_DIR/playmode.xml" ] && ! grep -q flaky-passed "$tmp/err"'
KNOWN_FLAKES="$tmp/none.txt" FAKE_FAILS="$ballers" EDITMODE_GFX=0 run editmode
check "no known-flakes file: every failure is real" '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'

# --- a fixture failure (OneTimeSetUp/TearDown) is a real failure -------------------------------------------------------------
. "$(dirname "$script")/test-passes.sh"
cat > "$tmp/fixture.xml" <<'EOF'
<test-run result="Failed"><test-suite type="Assembly" fullname="A" result="Failed" site="Child">
<test-suite type="TestFixture" fullname="X.Tests.Court" result="Failed" site="TearDown">
<test-case fullname="X.Tests.Court.TheBallersKeepPlaying" result="Failed" /><test-case fullname="X.Tests.Court.Ok" result="Passed" />
</test-suite><test-suite type="TestFixture" fullname="X.Tests.Setup" result="Failed"></test-suite>
<test-suite type="TestFixture" fullname="X.Tests.Fine" result="Failed" site="Child"><test-case fullname="X.Tests.Fine.A" result="Failed" /></test-suite>
</test-suite></test-run>
EOF
check "failed_tests lists failed cases and fixtures that failed on their own (site TearDown/SetUp, or no failed case)" \
  '[ "$(failed_tests "$tmp/fixture.xml" | sort | tr "\n" " ")" = "X.Tests.Court X.Tests.Court.TheBallersKeepPlaying X.Tests.Fine.A X.Tests.Setup " ]'
FAKE_FAILS="$ballers" FAKE_SUITE_FAILS=X.Tests.Court EDITMODE_GFX=0 run editmode
check "a fixture TearDown failure next to a listed flake fails the pass, no rerun" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q "X.Tests.Court failed and is not a known flake" "$tmp/err" && ! grep -q flaky-passed "$tmp/err"'

# --- the other passes -----------------------------------------------------------------------------------------------------
FAKE_FAILS="$ballers" run editmode
check "editmode: each pass retries its own flakes (editmode-retry.xml and editmode-gfx-retry.xml)" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 4 ] && [ -f "$OUT_DIR/editmode-retry.xml" ] && [ -f "$OUT_DIR/editmode-gfx-retry.xml" ] && [ "$(grep -c flaky-passed "$tmp/err")" = 2 ]'
FAKE_FAILS="$ballers" run playmode
check "playmode retries known flakes too" '[ "$rc" = 0 ] && [ -f "$OUT_DIR/playmode-retry.xml" ] && grep -q flaky-passed "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
