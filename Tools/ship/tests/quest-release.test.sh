#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"


# Keep the entry point and its sourced modules within the hub's source-size ceiling.
for file in "$(dirname "$script")/tests/quest-release.test.sh" "$(dirname "$script")"/tests/quest-release-flow-*.test.sh "$(dirname "$script")"/tests/lib/quest-release-*.sh; do
  check "${file##*/} fits the hub source-size ceiling" \
    '[ "$(wc -l < "$file")" -le 800 ] && [ "$(wc -c < "$file")" -le 51200 ]'
done

# --- prepare -------------------------------------------------------------------------------------------------------------------
# Exercise the unset caller case explicitly, even under run.sh's noninteractive environment.
unset GIT_TERMINAL_PROMPT GIT_SSH_COMMAND
FAKE_FREE_GB=12 run prepare
check "prepare refuses under 25 GB free and creates no worktree" \
  '[ "$rc" != 0 ] && out_has "only 12 GB free" && [ ! -d "$root/rel-$short-test" ] && ! [ -f "$tmp/git.log" ]'
run prepare
check "prepare fetches and makes rel-<sha>-test and rel-<sha>-build at origin/main" \
  '[ "$rc" = 0 ] && [ -f "$tmp/git.log" ] && [ "$(git -C "$root/rel-$short-test" rev-parse HEAD)" = "$sha" ] && [ "$(git -C "$root/rel-$short-build" rev-parse HEAD)" = "$sha" ]'
check "each worktree has its own Library copy, never a symlink" \
  '[ -d "$root/rel-$short-build/Library" ] && [ ! -L "$root/rel-$short-build/Library" ] && [ ! -L "$root/rel-$short-test/Library" ] && [ -f "$root/rel-$short-test/Library/Bee/cache" ] && [ "$(wc -l < "$tmp/clone.log")" = 2 ]'
check "the warm worktree is untouched" '[ "$(cat "$root/mac-pass/Library/Bee/cache")" = warm ] && [ ! -d "$root/mac-pass/.git" ]'
check "the run folder holds a summary with the commit" 'grep -q "commit:      $short (origin/main)" "$root"/release-logs/"$short"-*/summary.txt'

check "fetch disables terminal and SSH prompts without changing the caller environment" \
  'grep -q "^prompt=0 ssh=" "$tmp/fetch-env" && grep -q -- "-o BatchMode=yes" "$tmp/fetch-env" && grep -q "; qr_ssh 1 ssh$" "$tmp/fetch-env" && [ "${GIT_TERMINAL_PROMPT-unset}" = unset ] && [ "${GIT_SSH_COMMAND-unset}" = unset ]'
for cmd in prepare all; do
  reset_logs
  FAKE_FETCH_RC=128 GIT_SSH_COMMAND='ssh -i /fake/key' run "$cmd"
  check "$cmd fetch failure fails fast with authentication guidance and no Unity or device calls" \
    '[ "$rc" != 0 ] && out_has "non-interactive.*authenticate.*ssh-agent.*retry prepare" && [ ! -f "$tmp/unity.log" ] && [ ! -f "$tmp/adb.log" ] && grep -q "^prompt=0 ssh=" "$tmp/fetch-env" && grep -q -- "-o BatchMode=yes" "$tmp/fetch-env" && grep -q "; qr_ssh 1 ssh -i /fake/key$" "$tmp/fetch-env"'
done
run prepare

# A failed status inspection must never count as clean, either on reuse or cleanup.
FAKE_STATUS_FAIL=1 run prepare
check "prepare refuses a worktree when git status fails" '[ "$rc" != 0 ] && out_has "cannot inspect" && [ -d "$root/rel-$short-test" ]'
rc=0; ( qr_config; FAKE_STATUS_FAIL=1; qr_load_state; qr_cleanup_one "$root/rel-$short-test" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
check "cleanup preserves worktrees when git status fails" '[ "$rc" != 0 ] && [ -d "$root/rel-$short-test" ] && [ -d "$root/rel-$short-build" ] && out_has "inspection failed"'
run prepare
check "prepare recovers after status is readable" '[ "$rc" = 0 ]'
# A rejected dirty build worktree must not become a usable prepared release.
echo dirty >> "$root/rel-$short-build/Assets/Scripts/C.cs"
run prepare
check "failed dirty prepare does not publish current.env" \
  '[ "$rc" != 0 ] && out_has "local changes" && [ ! -f "$root/release-logs/current.env" ]'
reset_logs; run build
check "build after a failed prepare cannot consume the dirty worktree" \
  '[ "$rc" != 0 ] && out_has "no prepared release" && [ ! -f "$tmp/unity.log" ]'
git -C "$root/rel-$short-build" checkout -- Assets/Scripts/C.cs
run prepare


qr_flow_finish
