#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# APK swapfile ownership, sizing defaults and editor ordering. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-swap.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"
apk_module
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

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
