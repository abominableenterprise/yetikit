#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# APK parallelism caps and command isolation. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-resources.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"
apk_module

# --- parallelism cap -----------------------------------------------------------------------------------------------
check "apk: the editor gets il2cpp --jobs=2 and BEE_BUILD_THREADS=2 by default" \
  'lu apk && [ "$(cat "$tmp/jobs-env")" = "$(printf "BEE_BUILD_THREADS=2\nIL2CPP_ADDITIONAL_ARGS=--jobs=2")" ] && grep -q "capped at 2 parallel jobs" "$tmp/err"'
check "apk: APK_JOBS=3 sets both caps to 3" \
  'APK_JOBS=3 lu apk && grep -qx "BEE_BUILD_THREADS=3" "$tmp/jobs-env" && grep -qx "IL2CPP_ADDITIONAL_ARGS=--jobs=3" "$tmp/jobs-env"'
check "apk: an IL2CPP_ADDITIONAL_ARGS from the caller is kept, --jobs appended" \
  'IL2CPP_ADDITIONAL_ARGS=--foo lu apk && grep -qx "IL2CPP_ADDITIONAL_ARGS=--foo --jobs=2" "$tmp/jobs-env"'
check "apk: APK_JOBS=0 leaves the Unity defaults (no cap)" \
  'APK_JOBS=0 lu apk && [ ! -s "$tmp/jobs-env" ] && ! grep -q "capped at" "$tmp/err"'
check "apk: the caps reach only the apk editor run, not other commands (open)" \
  ': > "$tmp/jobs-env"; lu open && [ ! -s "$tmp/jobs-env" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
