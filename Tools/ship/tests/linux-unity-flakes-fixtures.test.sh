#!/usr/bin/env bash
# Synthetic editor regressions: flakes fixtures.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-flakes-fixture.sh
. "$(dirname "$0")/lib/linux-unity-flakes-fixture.sh"

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


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
