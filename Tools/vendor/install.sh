#!/usr/bin/env bash
# Serialize bumps without leaving a lock file; the project directory is the lock inode.
lock_project() {
  exec {project_lock}< "$project" || fail 'cannot open project lock'
  flock -n -E 75 "$project_lock" || {
    if [[ $? == 75 ]]; then fail 'another kit-bump is running for this project'; fi
    fail 'cannot lock project'
  }
}

prepare_install() {
  trap finish_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tools=$project/Tools
  old=$tools/yetikit
  if [[ ! -d $tools ]]; then
    mkdir -- "$tools"
    created_tools=1
  fi
  # Each replacement is staged beside its target, even on split mounts.
  work=$(mktemp -d "$tools/.kit-bump.XXXXXX")
  manifest_work=$(mktemp -d "$project/Packages/.kit-bump.XXXXXX")
  ship=$work/ship
  staged_manifest=$manifest_work/manifest.json
}

move_ship() {
  # GNU mv -n can return success without renaming. Verify that it did move.
  mv -nT -- "$1" "$2" && [[ ! -e $1 ]] || return 1
}

install_bundle() {
  if [[ -e $old ]]; then
    move_ship "$old" "$work/previous" || fail 'cannot back up Ship'
  fi
  move_ship "$ship" "$old" || fail 'cannot install Ship'
  mv -fT -- "$staged_manifest" "$manifest" || fail 'cannot replace manifest.json'
}

finish_install() {
  local status=$?
  trap '' INT TERM
  # The final manifest rename commits both replacements. Inspect the staged
  # paths rather than flags so a signal just after a rename is handled too.
  if [[ -n ${staged_manifest:-} && -e $staged_manifest ]]; then
    if [[ ! -e $ship ]]; then
      move_ship "$old" "$ship" || fail "cannot unwind Ship installation; recovery files remain in $work"
    fi
    if [[ -e $work/previous ]]; then
      move_ship "$work/previous" "$old" || fail "cannot restore Ship; backup remains in $work/previous"
    fi
  fi
  if [[ -n ${work:-} ]]; then rm -rf -- "$work"; fi
  if [[ -n ${manifest_work:-} ]]; then rm -rf -- "$manifest_work"; fi
  if [[ ${created_tools:-0} == 1 ]]; then rmdir -- "$tools" 2>/dev/null || true; fi
  exit "$status"
}
