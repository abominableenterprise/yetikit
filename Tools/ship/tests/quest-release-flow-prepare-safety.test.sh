#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check evaluates conditions with fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

test_wt="$root/rel-$short-test"; build_wt="$root/rel-$short-build"
state="$root/release-logs/current.env"
clone_count() { wc -l < "$tmp/clone.log"; }
qr_clone_dir() {
  echo "$1 -> $2" >> "$tmp/clone.log"
  if [ "${FAIL_CLONE:-0}" = 1 ]; then
    mkdir -p "$2" && echo incomplete > "$2/partial"
    return 1
  fi
  cp -R "$1" "$2"
}

FAIL_CLONE=1 run prepare
check 'a failed copy publishes neither a Library nor prepared state' \
  '[ "$rc" != 0 ] && [ ! -e "$test_wt/Library" ] && [ ! -e "$state" ]'
run prepare
check 'prepare retries the interrupted clone instead of using partial files' \
  '[ "$rc" = 0 ] && [ "$(clone_count)" = 3 ] && [ -f "$test_wt/Library/Bee/cache" ] && [ ! -e "$test_wt/Library/partial" ] && [ -f "$state" ]'

run prepare
check 'prepare reuses both completed clones' '[ "$rc" = 0 ] && [ "$(clone_count)" = 3 ]'

# A legacy partial copy may already occupy the final path; keep it for inspection.
mv "$test_wt/Library" "$tmp/complete"
mkdir "$test_wt/Library" && echo partial > "$test_wt/Library/partial" || exit 1
run prepare
check 'prepare rejects a legacy partial Library without deleting it' \
  '[ "$rc" != 0 ] && out_has "not a verified clone" && [ ! -e "$state" ] && [ -f "$test_wt/Library/partial" ]'
mv "$test_wt/Library" "$tmp/partial" && mv "$tmp/complete" "$test_wt/Library" || exit 1

git -C "$repo" worktree remove "$build_wt" || exit 1
ln -s "$test_wt" "$build_wt" || exit 1
run prepare
check 'prepare refuses a release worktree symlink pointing to its peer' \
  '[ "$rc" != 0 ] && [ -L "$build_wt" ] && [ ! -e "$state" ] && [ "$(clone_count)" = 3 ]'
rm "$build_wt"
ln -s "$tmp/missing" "$build_wt" || exit 1
run prepare
check 'prepare refuses a dangling release worktree symlink before adding it' \
  '[ "$rc" != 0 ] && out_has "symlink" && [ -L "$build_wt" ] && [ ! -e "$state" ]'
rm "$build_wt"

# A copied .git link reaches the right repo and commit, but is not registered at this path.
cp -R "$test_wt" "$build_wt" || exit 1
run prepare
check 'prepare refuses a directory with copied worktree metadata' \
  '[ "$rc" != 0 ] && [ ! -e "$state" ] && [ "$(clone_count)" = 3 ]'

qr_flow_finish
