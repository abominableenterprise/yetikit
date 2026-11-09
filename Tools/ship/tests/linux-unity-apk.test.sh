#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# APK build arguments, reports, validation and failures. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"

# --- apk -----------------------------------------------------------------------------------------------------------
check "apk without the Android module stops before the editor and names setup --android" \
  ': > "$tmp/runs"; ! lu apk && grep -q "setup --android" "$tmp/err" && [ ! -s "$tmp/runs" ]'
apk_module
check "apk (default dev) succeeds" ': > "$tmp/runs"; lu apk'
check "apk dev: one editor run, Android target, DevelopmentApk, log in OUT_DIR/apk.log" \
  '[ "$(wc -l < "$tmp/runs")" = 1 ] && grep -q -- "-batchmode -projectPath $proj -quit -buildTarget Android -executeMethod ExampleGame.World.Editor.WorldBuild.DevelopmentApk -logFile $OUT_DIR/apk.log" "$tmp/runs"'
check "apk dev: never -nographics (the player build needs a graphics device)" '! grep -q -- -nographics "$tmp/runs"'
check "apk dev: prints the APK path, size and sha256" \
  'grep -q "apk: $proj/Builds/Android/GeneratedScene-dev.apk" "$tmp/err" && grep -q "apk: size 3 bytes" "$tmp/err" && grep -q "apk: sha256 $(printf apk | sha256sum | cut -c1-64)" "$tmp/err"'
check "apk contest: ContestApk and ExampleGame-contest.apk" \
  ': > "$tmp/runs"; lu apk contest && grep -q "WorldBuild.ContestApk" "$tmp/runs" && grep -q "apk: $proj/Builds/Android/ExampleGame-contest.apk" "$tmp/err"'
check "apk release aliases the configured contest build" \
  ': > "$tmp/runs"; lu apk release && grep -q "WorldBuild.ContestApk" "$tmp/runs"'
check "apk with an unknown kind is a usage error, no editor run" ': > "$tmp/runs"; ! lu apk unknown && grep -q "usage: apk" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "apk with extra arguments is a usage error" '! lu apk dev extra && grep -q "usage: apk" "$tmp/err"'
check "apk: a failed editor run fails with the log path" \
  '! FAKE_UNITY_RC=1 lu apk && grep -q "DevelopmentApk failed (exit 1; see $OUT_DIR/apk.log)" "$tmp/err"'
check "apk: a build that writes no APK fails and never reports the old one" \
  '! FAKE_NO_APK=1 lu apk && grep -q "wrote no Builds/Android/GeneratedScene-dev.apk" "$tmp/err" && ! grep -q "apk: sha256" "$tmp/err"'
check "apk: the pidfile is gone afterwards" '[ ! -f "$OUT_DIR/linux-unity.pid" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
