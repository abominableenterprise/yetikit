#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android build scratch, failed builds and existing Library cache bypass. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-cache-cleanup.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-cache.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-cache.sh"

check "apk removes the Android build scratch .utmp/ from the project root" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p .utmp/Debug" lu apk && [ ! -e "$proj/.utmp" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "a failed cold build saves no cache" \
  '! TASK_CACHE=fake-cache FAKE_UNITY_RC=1 lu apk && ! grep -q "^save" "$tmp/cache-calls"'
: > "$tmp/cache-calls"
check "apk with a Library/ never touches the cache" 'mkdir -p "$proj/Library" && TASK_CACHE=fake-cache lu apk && [ ! -s "$tmp/cache-calls" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
