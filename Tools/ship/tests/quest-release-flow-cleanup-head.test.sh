#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # check evaluates conditions with fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

# Use the real noise config reads rather than the flow fixture's cached keys.
eval "$(declare -f qr_config_get | awk 'NR == 1 { sub(/^qr_config_get/, "cached_qr_config_get") } { print }')"
qr_config_get() {
  case "$1" in .noise.*) jq -r "$1" <<< "$QR_CONFIG_JSON" ;; *) cached_qr_config_get "$1" ;; esac
}

mat=Assets/Mats/A.mat
printf '  m_Floats:\n  - _ZTest: 4\n' > "$repo/$mat"
git -C "$repo" add -- "$mat" && git -C "$repo" commit -qm 'Material fixture' || exit 1
git -C "$repo" update-ref refs/remotes/origin/main HEAD || exit 1
sha="$(git -C "$repo" rev-parse HEAD)"; short="${sha:0:9}"
qr_flow_prepare
test_wt="$root/rel-$short-test"
tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')" || exit 1
moved="$(git -C "$repo" commit-tree "$tree" -p "$sha" -m 'Different commit, identical tree')" || exit 1

# Inject the move at a completed Git operation, avoiding timing or sleeps.
# Two commits with the same tree leave status and the HEAD-relative patch unchanged.
git() {
  command git "$@" || return $?
  [ ! -e "$tmp/head-moved" ] || return 0
  case "${move_at:-}:${1:-}:${3:-}" in
    diff:-c:diff)
      [ "$PWD" -ef "$test_wt" ] || return 0
      # Move after capturing the second (comparison) patch.
      if [ ! -e "$tmp/patch-captured" ]; then : > "$tmp/patch-captured"; return 0; fi ;;
    apply:-c:apply) [ "$PWD" -ef "$test_wt" ] || return 0 ;;
    status:-C:status) [ "$2" = "$test_wt" ] || return 0 ;;
    *) return 0 ;;
  esac
  command git -C "$test_wt" update-ref --no-deref HEAD "$moved" "$sha" || exit 1
  : > "$tmp/head-moved"
}

reset_test_worktree() {
  if [ -d "$test_wt" ]; then
    command git -C "$repo" worktree remove --force "$test_wt" || exit 1
  fi
  command git -C "$repo" worktree add -q --detach "$test_wt" "$sha" || exit 1
  rm -f "$tmp/head-moved"
}

printf '  m_Floats:\n  - _ZTest: 8\n' > "$test_wt/$mat"
command git -C "$test_wt" diff --binary HEAD -- > "$tmp/expected.patch" || exit 1
move_at=diff run cleanup --discard-noise
check 'HEAD move during noise inspection preserves the detached commit and unchanged patch' \
  '[ "$rc" != 0 ] && [ -e "$tmp/head-moved" ] && [ "$(git -C "$test_wt" rev-parse HEAD)" = "$moved" ] &&
   git -C "$test_wt" diff --binary HEAD -- > "$tmp/actual.patch" && cmp -s "$tmp/expected.patch" "$tmp/actual.patch"'

reset_test_worktree
printf '  m_Floats:\n  - _ZTest: 8\n' > "$test_wt/$mat"
move_at=apply run cleanup --discard-noise
check 'HEAD move just after noise reversal still prevents removal of the clean worktree' \
  '[ "$rc" != 0 ] && [ -e "$tmp/head-moved" ] && [ "$(git -C "$test_wt" rev-parse HEAD)" = "$moved" ] &&
   git -C "$test_wt" status --porcelain > "$tmp/after-status" && [ ! -s "$tmp/after-status" ]'

reset_test_worktree
move_at=status run cleanup
check 'plain cleanup preserves a clean worktree whose HEAD moved after status inspection' \
  '[ "$rc" != 0 ] && [ -e "$tmp/head-moved" ] && [ "$(git -C "$test_wt" rev-parse HEAD)" = "$moved" ]'

reset_test_worktree
git -C "$test_wt" checkout -qb attached || exit 1
run cleanup
check 'plain cleanup preserves a worktree attached to a branch even at the expected commit' \
  '[ "$rc" != 0 ] && [ "$(git -C "$test_wt" symbolic-ref HEAD)" = refs/heads/attached ]'

qr_flow_finish
