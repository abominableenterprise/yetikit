#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# Stop finds and kills an all run hung in the fake licence return.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-stop-return.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

# #180 review: a hung licence return keeps the pidfile, so stop still finds the run.
rm -f "$tmp/return.pid"
UNITY_USERNAME=u UNITY_PASSWORD=p UNITY_RETURN_ON_EXIT=1 FAKE_RETURN_SLEEP=300 bash "$script" all >/dev/null 2>&1 & runner=$!
for i in $(seq 600); do [ -s "$tmp/return.pid" ] && break; sleep 0.1; done  # all runs setup..test first
check "all: the pidfile still names the run during the licence return" \
  '[ -s "$tmp/return.pid" ] && [ "$(cut -d" " -f1 "$OUT_DIR/linux-unity.pid")" = "$runner" ]'
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
check "all: stop kills a hung licence return" \
  '! kill -0 "$runner" 2>/dev/null && ! kill -0 "$(cat "$tmp/return.pid")" 2>/dev/null && grep -q "stop: killing $runner" "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
