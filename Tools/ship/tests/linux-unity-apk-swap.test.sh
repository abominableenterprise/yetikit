#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# APK swapfile ownership, cleanup, cancellation, licence return and timeout. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-swap.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"
apk_module

# --- swapfile --------------------------------------------------------------------------------------------------------
swapfiles() { find "$tmp/swap" -name "linux-unity-apk.swap.*" | wc -l; }
: > "$tmp/swap-calls"
check "apk on a 16 GB VM adds no swapfile" 'lu apk && [ ! -s "$tmp/swap-calls" ]'
check "apk ignores inherited swap cleanup ownership and preserves the sentinel file" \
  'printf "keep\n" > "$tmp/inherited-swap"; APK_SWAPFILE="$tmp/inherited-swap" lu apk && [ -f "$tmp/inherited-swap" ] && [ "$(cat "$tmp/inherited-swap")" = keep ] && [ ! -s "$tmp/swap-calls" ]'
check "apk on an 8 GB VM that already has swap adds none" 'MEMINFO="$tmp/meminfo-8g-swap" lu apk && [ ! -s "$tmp/swap-calls" ]'
check "apk on an 8 GB VM without swap: a 3 GB swapfile is on during the build and removed afterwards" \
  ': > "$tmp/swap-calls"; MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "^fallocate -l 3G $tmp/swap/linux-unity-apk.swap." "$tmp/swap-calls" && grep -q "^swapon $tmp/swap/" "$tmp/swap-calls" && grep -q "^swapoff $tmp/swap/" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ] && grep -q "removed swapfile" "$tmp/err"'
check "swapon comes before the editor run, swapoff after it" \
  ': > "$tmp/swap-calls"; FAKE_MUTATE="echo editor >> \"$tmp/swap-calls\"" MEMINFO="$tmp/meminfo-8g" lu apk; [ "$(grep -oE "^(swapon|editor|swapoff)" "$tmp/swap-calls" | tr "\n" " ")" = "swapon editor swapoff " ]'
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
check "a swapfile that could not be created: warning, build goes on, nothing to remove" \
  ': > "$tmp/swap-calls"; FAKE_FALLOCATE_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "could not create" "$tmp/err" && ! grep -q "^swapoff" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ]'
check "swapon refused (overlay root): warning, build goes on, the file is still removed" \
  ': > "$tmp/swap-calls"; FAKE_SWAPON_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "swapon .* failed" "$tmp/err" && [ "$(swapfiles)" = 0 ]'
# UNITY_RETURN_ON_EXIT=1: apk's swapfile trap chains onto the licence return trap (both run, the failure is kept).
lcdir="$tmp/unity/Editor/Data/Resources/Licensing/Client"; mkdir -p "$lcdir"
printf '#!/bin/sh\necho "$1" >> "%s/lc-calls"\n[ "$1" != --activate-ulf ] || cp "%s/ulf.good" "$ULF"\n' "$tmp" "$tmp" > "$lcdir/Unity.Licensing.Client"
chmod +x "$lcdir/Unity.Licensing.Client"; cp "$ULF" "$tmp/ulf.good"
check "apk with UNITY_RETURN_ON_EXIT=1 that activated: a failed build removes the swapfile and returns the licence" \
  ': > "$tmp/swap-calls"; : > "$tmp/lc-calls"; rm -f "$ULF"; ! UNITY_RETURN_ON_EXIT=1 UNITY_USERNAME=u UNITY_PASSWORD=p FAKE_UNITY_RC=1 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "^swapoff" "$tmp/swap-calls" && [ "$(swapfiles)" = 0 ] && grep -q -- "^--return-ulf" "$tmp/lc-calls" && [ ! -f "$OUT_DIR/linux-unity.pid" ]'
cp "$tmp/ulf.good" "$ULF"
check "a stale swapfile of a KILLed run is swapped off and removed; one of a live run is kept" \
  'sleep 30 & live=$!; : > "$tmp/swap/linux-unity-apk.swap.999999"; : > "$tmp/swap/linux-unity-apk.swap.$live"; : > "$tmp/swap-calls"; lu apk; rc=$?; kill "$live"; [ "$rc" = 0 ] && [ ! -e "$tmp/swap/linux-unity-apk.swap.999999" ] && grep -q "^swapoff $tmp/swap/linux-unity-apk.swap.999999" "$tmp/swap-calls" && [ -e "$tmp/swap/linux-unity-apk.swap.$live" ] && rm -f "$tmp/swap/linux-unity-apk.swap.$live"'

check "apk: the editor runs under APK_TIMEOUT (default 5400 s), not UNITY_TIMEOUT" \
  'printf "#!/usr/bin/env bash\necho \"\$*\" > \"%s/timeout-args\"\nshift 3; exec \"\$@\"\n" "$tmp" > "$tmp/bin/timeout" && chmod +x "$tmp/bin/timeout" && lu apk && grep -q "^-s KILL 5400 " "$tmp/timeout-args" && APK_TIMEOUT=9 lu apk && grep -q "^-s KILL 9 " "$tmp/timeout-args"; rm -f "$tmp/bin/timeout"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
