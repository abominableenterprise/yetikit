#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android cache fallback, partial restore and save recovery. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-cache-save.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-cache.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-cache.sh"

rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk with an Android miss falls back to the editor cache, then saves under the Android key" \
  'TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && [ "$(tr "\n" " " < "$tmp/cache-calls")" = "restore $ka restore $k save $ka " ] && grep -q "apk: cache: editor fallback" "$tmp/err"'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk: restore exit 3 cleans partial cache, imports cold, then saves Android cache" \
  'TASK_CACHE=fake-cache FAKE_PARTIAL=1 lu apk && grep -q "cache restore failed (exit 3); cold import" "$tmp/err" && grep -q "apk: cache: cold import" "$tmp/err" && [ ! -e "$proj/Library/partial" ] && [ ! -e "$proj/.task-cache.partial" ] && [ "$(tr "\n" " " < "$tmp/cache-calls")" = "restore $ka restore $k save $ka " ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "the cold save leaves Library/Bee out of the cache and puts it back afterwards" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p Library/Bee && echo x > Library/Bee/obj" TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && grep -qx "save $ka nobee" "$tmp/cache-bee" && [ -f "$proj/Library/Bee/obj" ] && [ ! -e "$proj/Temp/apk-bee-aside" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "a failed cold save still puts Library/Bee back" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p Library/Bee && echo x > Library/Bee/obj" FAKE_SAVE_RC=1 TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && grep -q "cache-save failed" "$tmp/err" && [ -f "$proj/Library/Bee/obj" ] && [ ! -e "$proj/Temp/apk-bee-aside" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
