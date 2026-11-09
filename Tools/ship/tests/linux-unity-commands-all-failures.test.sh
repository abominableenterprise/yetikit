#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# All return-failure precedence, return execution and pidfile cleanup with a fake editor.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-all-failures.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

all FAKE_RETURN_RC=7
check "all: a failed return alone exits nonzero (its code)" \
  '[ "$rc" = 7 ] && grep -q "licence return failed (exit 7)" "$tmp/err"'
all FAKE_RETURN_RC=7 FAKE_UNITY_RC=3
check "all: an earlier failure keeps its exit code when the return also fails" '[ "$rc" = 1 ] && grep -q "licence return failed" "$tmp/err"'
check "all: the return still runs after an earlier failure" 'grep -q -- "--return-ulf" "$tmp/lc-calls"'
check "all: the pidfile is gone once all has exited" '[ ! -f "$OUT_DIR/linux-unity.pid" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
