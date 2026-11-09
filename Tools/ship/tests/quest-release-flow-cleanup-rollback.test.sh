#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_prepare

# --- rollback ----------------------------------------------------------------------------------------------------------------------
old="$tmp/consumer-dev-old.apk"; echo old > "$old"
reset_logs; run rollback "$old"
check "rollback installs -r -d the previous APK (lower versionCode) with the same data checks" \
  '[ "$rc" = 0 ] && grep -q "^-s $serial install -r -d $old$" "$tmp/adb.log" && grep -q "data hash:   configured data files unchanged" "$tmp/out" && grep -q "install:     rollback ok" "$tmp/out"'

# --- cleanup -----------------------------------------------------------------------------------------------------------------------
echo noise >> "$root/rel-$short-test/Assets/Mats/A.mat"; echo noise >> "$root/rel-$short-test/Assets/Mats/B.asset"
echo real >> "$root/rel-$short-build/Assets/Scripts/C.cs"
run cleanup
check "cleanup preserves material and asset edits without guessing noise" '[ "$rc" != 0 ] && [ -d "$root/rel-$short-test" ]'
check "cleanup keeps a worktree with a changed .cs file and says why" \
  '[ "$rc" != 0 ] && [ -d "$root/rel-$short-build" ] && out_has "keeping $root/rel-$short-build: local changes"'
check "cleanup never touches the warm worktree" '[ -f "$root/mac-pass/Library/Bee/cache" ]'
git -C "$repo" worktree remove --force "$root/rel-$short-test"
git -C "$repo" worktree remove --force "$root/rel-$short-build"
# A staged rename is local work regardless of either path's extension.
run prepare
mkdir -p "$root/rel-$short-test/Assets/Scripts"
git -C "$root/rel-$short-test" mv Assets/Scripts/C.cs Assets/Scripts/C.asset
run cleanup
check "cleanup preserves staged source-to-asset renames" '[ "$rc" != 0 ] && [ -f "$root/rel-$short-test/Assets/Scripts/C.asset" ] && out_has "local changes"'
git -C "$repo" worktree remove --force "$root/rel-$short-test"
[ -d "$root/rel-$short-build" ] && git -C "$repo" worktree remove --force "$root/rel-$short-build"


qr_flow_finish
