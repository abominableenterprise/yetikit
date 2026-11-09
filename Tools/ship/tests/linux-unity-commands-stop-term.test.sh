#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# Stop kills a fake licence return forked by TERM during its grace period.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-stop-term.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

# #180 review: stop TERMs an all run mid-editor; its EXIT trap forks the licence return, which hangs (and would
# outlive the snapshot). It carries the run's LINUX_UNITY_RUN marker, so stop's final sweep still reaches it.
rm -f "$tmp/return.pid" "$tmp/editor.pid"
UNITY_USERNAME=u UNITY_PASSWORD=p UNITY_RETURN_ON_EXIT=1 FAKE_EDITOR_SLEEP=300 FAKE_RETURN_SLEEP=300 bash "$script" all >/dev/null 2>&1 & runner=$!
for i in $(seq 600); do [ -s "$tmp/editor.pid" ] && break; sleep 0.1; done
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
ret="$(cat "$tmp/return.pid" 2>/dev/null || true)"
# A killed pid can stay a zombie for a moment until init reaps it: that counts as gone.
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
check "all: a licence return forked by TERM during stop's grace period is killed too" \
  '[ -n "$ret" ] && ! alive "$ret" && ! alive "$(cat "$tmp/editor.pid")"'
[ -z "$ret" ] || ! alive "$ret" || kill -9 "$ret"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
