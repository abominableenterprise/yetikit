# shellcheck shell=bash
# Verify the linked worktree's physical root, repository and registration backlink.
qr_registered_worktree() (
  local wt="$1" top common expected admin backlink parent
  [ ! -L "$wt" ] && [ -f "$wt/.git" ] && [ ! -L "$wt/.git" ] || return 1
  cd -P -- "$wt" || return 1
  top="$(git rev-parse --show-toplevel)" || return 1
  common="$(git rev-parse --path-format=absolute --git-common-dir)" || return 1
  expected="$(qr_git rev-parse --path-format=absolute --git-common-dir)" || return 1
  admin="$(git rev-parse --absolute-git-dir)" || return 1
  [ "$top" = "$PWD" ] && [ "$common" -ef "$expected" ] &&
    [ "$(dirname -- "$admin")" -ef "$common/worktrees" ] || return 1
  IFS= read -r backlink < "$admin/gitdir" || return 1
  # Git's relative worktree links (when enabled) are relative to the admin directory.
  case "$backlink" in /*) ;; *) backlink="$admin/$backlink" ;; esac
  parent="$(cd -P -- "$(dirname -- "$backlink")" && pwd -P)" || return 1
  [ "$parent" = "$PWD" ] && [ "${backlink##*/}" = .git ]
)

# symbolic-ref exits 1 for a detached HEAD; any other result is unsafe.
qr_expected_worktree_head() {
  local wt="$1" sha="$2" symbolic_rc=0 head
  git -C "$wt" symbolic-ref --quiet HEAD >/dev/null 2>&1 || symbolic_rc=$?
  [ "$symbolic_rc" = 1 ] && head="$(git -C "$wt" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" &&
    [ "$head" = "$sha" ]
}

qr_library_ready() {
  [ -d "$1/Library" ] && [ ! -L "$1/Library" ] &&
    [ -f "$1/Library/.quest-release-clone-complete" ] && [ ! -L "$1/Library/.quest-release-clone-complete" ]
}

qr_check_prepared_worktree() {
  local wt="$1" apk="${2:-}"
  [ -d "$wt" ] || qr_die "no release worktree $wt: run prepare first"
  qr_library_ready "$wt" || qr_die "$wt/Library is not a verified clone; move it aside and rerun prepare"
  qr_check_release_noise "$wt" "$apk" || qr_die "$wt has local changes or could not be inspected; Unity was not started"
}
