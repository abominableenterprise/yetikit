#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android cache keys, hits and post-restore disk checks. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-cache.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-cache.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-cache.sh"

check "cache-key android is a different bare 64-hex key" '[[ "$ka" =~ ^[0-9a-f]{64}$ ]] && [ "$ka" != "$k" ]'
check "cache-key (no argument) is unchanged by the android variant" \
  '[ "$k" = "$({ cat "$proj/Packages/manifest.json" "$proj/Packages/packages-lock.json" "$proj/ProjectSettings/ProjectVersion.txt"; printf 6000.6.6f1; } | sha256sum | cut -c1-64)" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk with no Library/ and an Android cache hit restores it and saves nothing" \
  'TASK_CACHE=fake-cache FAKE_HIT="$ka" lu apk && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ] && grep -q "apk: cache: Android hit" "$tmp/err"'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"; : > "$tmp/runs"
check "apk: warm Android restore passes post-restore disk check and starts the editor" \
  'TASK_CACHE=fake-cache FAKE_HIT="$ka" FAKE_WARM_RESTORE=1 FAKE_FREE_GB=10 FAKE_DISK_MARKER="$proj/Library/hit" FAKE_RESTORE_FREE_GB=4 lu apk && grep -q "need 4 GB, warm: Library/Bee/Android" "$tmp/err" && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"; : > "$tmp/runs"
check "apk: restored Library crosses cold threshold: fail post-restore before editor" \
  '! TASK_CACHE=fake-cache FAKE_HIT="$ka" FAKE_FREE_GB=10 FAKE_DISK_MARKER="$proj/Library/hit" FAKE_RESTORE_FREE_GB=9 lu apk && grep -q "post-restore.*only 9 GB free.*need 10 GB" "$tmp/err" && [ ! -s "$tmp/runs" ] && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ] && [ ! -e "$OUT_DIR/linux-unity.pid" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
