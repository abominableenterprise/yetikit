#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_prepare

# --- build and verify ------------------------------------------------------------------------------------------------------
apk="$root/mac-pass/Builds/Android/consumer-dev-$short.apk"
reset_logs; run build
check "build runs Synthetic.Editor.Build.DevelopmentApk for Android in the build worktree" \
  '[ "$rc" = 0 ] && grep -q -- "-projectPath $root/rel-$short-build -buildTarget Android -executeMethod Synthetic.Editor.Build.DevelopmentApk -quit -logFile" "$tmp/unity.log"'
check "build keeps the APK as consumer-dev-<sha>.apk in mac-pass/Builds/Android" \
  'grep -q "apk built in $root/rel-$short-build" "$apk" && grep -q "apk:         $apk" "$tmp/out"'
check "build with no --notes and no installed build in the logs leaves both notes variables unset" \
  'grep -q "^notes= prev=$" "$tmp/notes-env.log" && grep -q "notes:       merge titles since the last 8 merges" "$tmp/out"'
notes="$tmp/whats-new.txt"; printf -- '- Pick who is playing\nBuild number on the start panel\n' > "$notes"
logs="$root/release-logs"
mkdir -p "$logs/abc123456-20200101-000000/summary" "$logs/def987654-20200102-000000/summary"
echo "install ok (/x.apk)" > "$logs/abc123456-20200101-000000/summary/install"
echo "abc123456 (origin/main)" > "$logs/abc123456-20200101-000000/summary/commit"
echo "abc123456" > "$logs/abc123456-20200101-000000/summary/installed_commit"
echo "20200101-000000" > "$logs/abc123456-20200101-000000/summary/installed_at"
echo "install FAILED: no" > "$logs/def987654-20200102-000000/summary/install" # newer, but not installed
echo "def987654 (origin/main)" > "$logs/def987654-20200102-000000/summary/commit"
reset_logs; run build --notes "$notes"
check "build --notes exports YETIKIT_WHATS_NEW (absolute) and YETIKIT_PREV_SHA from the last successful install" \
  '[ "$rc" = 0 ] && grep -q "^notes=$notes prev=abc123456$" "$tmp/notes-env.log" && grep -q "notes:       $notes" "$tmp/out"'
reset_logs; run build --notes "$tmp/nope.txt"
check "build --notes with a missing file fails before Unity runs" '[ "$rc" != 0 ] && out_has "does not exist" && [ ! -f "$tmp/unity.log" ]'
rm -rf "$logs/abc123456-20200101-000000" "$logs/def987654-20200102-000000"


qr_flow_finish
