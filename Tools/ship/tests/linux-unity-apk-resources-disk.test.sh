#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# APK cold/warm disk-space limits and swap headroom. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-resources-disk.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"
apk_module

# --- disk check ------------------------------------------------------------------------------------------------------
check "apk with under 10 GB free fails before the editor and says how much is free and needed" \
  ': > "$tmp/runs"; ! FAKE_FREE_GB=9 lu apk && grep -q "apk: only 9 GB free on / (need 10 GB" "$tmp/err" && grep -q "free disk first" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "apk with exactly 10 GB free builds" 'FAKE_FREE_GB=10 lu apk && grep -q "apk: 10 GB free (need 10 GB)" "$tmp/err"'
check "a warm rebuild (Library/Bee/Android there) needs only 4 GB" \
  'mkdir -p "$proj/Library/Bee/Android" && FAKE_FREE_GB=4 lu apk && grep -q "need 4 GB, warm: Library/Bee/Android" "$tmp/err" && ! FAKE_FREE_GB=3 lu apk && grep -q "need 4 GB: APK_MIN_FREE_GB_WARM=4" "$tmp/err"'
check "APK_MIN_FREE_GB_WARM changes the warm limit" '! FAKE_FREE_GB=5 APK_MIN_FREE_GB_WARM=6 lu apk && grep -q "need 6 GB" "$tmp/err"; rc=$?; rm -rf "$proj/Library/Bee"; [ "$rc" = 0 ]'
check "APK_MIN_FREE_GB changes the limit" '! FAKE_FREE_GB=10 APK_MIN_FREE_GB=12 lu apk && grep -q "need 12 GB" "$tmp/err"'
check "apk on an 8 GB VM counts the swapfile into the disk it needs (13 GB with 3 GB swap)" \
  ': > "$tmp/swap-calls"; ! FAKE_FREE_GB=12 MEMINFO="$tmp/meminfo-8g" lu apk && grep -q "need 13 GB: APK_MIN_FREE_GB=10 + 3 GB swap" "$tmp/err" && [ ! -s "$tmp/swap-calls" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
