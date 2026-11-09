#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# All succeeds when every fake-editor pass and licence return succeeds.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-all.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

# --- #47: all exits nonzero when the licence return is the only failure, keeps an earlier failure's code -----------
all FAKE_RETURN_RC=0
check "all: everything ok exits 0" '[ "$rc" = 0 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
