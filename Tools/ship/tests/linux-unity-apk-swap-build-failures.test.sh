#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# APK swap overrides, build failures and cancellation cleanup. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-swap-build-failures.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"
apk_module
swapfiles() { find "$tmp/swap" -name "linux-unity-apk.swap.*" | wc -l; }
: > "$tmp/swap-calls"

check "APK_SWAP_GB=4 makes a 4 GB swapfile; APK_SWAP_GB=0 none" \
  ': > "$tmp/swap-calls"; MEMINFO="$tmp/meminfo-8g" APK_SWAP_GB=4 lu apk && grep -q "^fallocate -l 4G" "$tmp/swap-calls" && : > "$tmp/swap-calls" && MEMINFO="$tmp/meminfo-8g" APK_SWAP_GB=0 lu apk && [ ! -s "$tmp/swap-calls" ]'
check "a failed build still removes the swapfile" \
  ': > "$tmp/swap-calls"; ! FAKE_UNITY_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "^swapoff" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ]'
check "a build that writes no APK still removes the swapfile" \
  '! FAKE_NO_APK=1 MEMINFO="$tmp/meminfo-8g" lu apk && [ "$(swapfiles)" = 0 ]'
: > "$tmp/swap-calls"
MEMINFO="$tmp/meminfo-8g" python3 - "$script" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ['FAKE_TMP'])
gate = root / 'apk-editor'
with (root / 'err').open('w') as log:
    runner = subprocess.Popen(['bash', sys.argv[1], 'apk'], stdout=log, stderr=log,
                              env=dict(os.environ, FAKE_EDITOR_GATE=str(gate)),
                              start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while not Path(str(gate) + '.ready').exists():
            assert runner.poll() is None, (root / 'err').read_text()
            assert time.monotonic() < deadline, 'APK editor never reached its gate'
            time.sleep(.02)
        assert any(line.startswith('swapon ') for line in (root / 'swap-calls').read_text().splitlines())
        runner.send_signal(signal.SIGTERM)
        # Bash may defer its handler until the foreground editor returns.
        Path(str(gate) + '.release').touch()
        assert runner.wait(timeout=60) == 143, (root / 'err').read_text()
    finally:
        Path(str(gate) + '.release').touch()
        if runner.poll() is None:
            os.killpg(runner.pid, signal.SIGKILL)
        runner.wait()
print('ok   APK wrapper receives TERM while the editor is gated and exits 143')
PY
check "apk TERMed mid-build removes the swapfile and its pidfile" \
  '[ "$(swapfiles)" = 0 ] && grep -q "^swapoff" "$tmp/swap-calls" && [ ! -f "$OUT_DIR/linux-unity.pid" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
