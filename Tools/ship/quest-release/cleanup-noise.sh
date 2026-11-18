# shellcheck shell=bash
# Discard only changes the shared Ship run-noise classifier recognizes. Run in
# a subshell so the worktree, classifier state and temporary files stay local.
qr_discard_noise() (
  local wt="$1" scratch record path reason top common expected
  [ ! -L "$wt" ] && [ -f "$wt/.git" ] && [ ! -L "$wt/.git" ] || return 2
  cd -P -- "$wt" || return 2
  top="$(git rev-parse --show-toplevel)" || return 2
  common="$(git rev-parse --path-format=absolute --git-common-dir)" || return 2
  expected="$(qr_git rev-parse --path-format=absolute --git-common-dir)" || return 2
  [ "$top" = "$PWD" ] && [ "$common" -ef "$expected" ] &&
    qr_cleanup_expected_head . || return 2

  scratch="$(mktemp -d)" || return 2
  trap 'rm -rf -- "$scratch"' EXIT
  # Git status (including the final removal's clean check) can miss edits to
  # assume-unchanged and skip-worktree entries. Do not discard in those trees.
  git ls-files -v -z > "$scratch/index-flags" || return 2
  while IFS= read -r -d '' record; do
    case "${record:0:1}" in
      [a-z]|S) qr_log "keeping $wt: cannot inspect hidden index entry ${record:2}"; return 2 ;;
    esac
  done < "$scratch/index-flags"
  qr_noise_status > "$scratch/status" || return 2
  [ -s "$scratch/status" ] || return 0
  qr_noise_patch > "$scratch/patch" || return 2
  # A patch may include permission/type changes even when its text looks like noise.
  if grep -Eq '^(old mode|new mode|new file mode|deleted file mode) ' "$scratch/patch"; then
    qr_log "keeping $wt: real changes (file mode, type, addition or deletion)"
    return 1
  fi

  # shellcheck source=Tools/ship/lib/run-noise.sh
  . "$QR_SHIP_DIR/lib/run-noise.sh" || return 2
  noise_init_run_config qr_config_get || return 2
  while IFS= read -r -d '' record; do
    path="${record:3}"
    if [ "${record:0:3}" != ' M ' ]; then
      qr_log "keeping $wt: real changes or unsupported status (staged, untracked or not a plain modification): $path"
      return 1
    fi
    if [ ! -f "$path" ] || [ -L "$path" ] || ! reason="$(noise_run_reason "$path")"; then
      qr_log "keeping $wt: real changes or unclassified editor noise: $path"
      return 1
    fi
    qr_log "recognized editor noise in $wt: $path ($reason)"
  done < "$scratch/status"

  # Do not overwrite files from the index or force removal. Reverse only the
  # inspected patch, and let ordinary Git removal reject any remaining edits.
  qr_noise_status > "$scratch/current-status" && cmp -s "$scratch/status" "$scratch/current-status" &&
    qr_noise_patch > "$scratch/current-patch" && cmp -s "$scratch/patch" "$scratch/current-patch" || return 2
  [ -s "$scratch/patch" ] || return 2
  qr_cleanup_expected_head . || return 2
  git -c apply.ignoreWhitespace=no apply --reverse --whitespace=nowarn "$scratch/patch" || return 2
)

qr_noise_status() {
  git -c core.filemode=true status --porcelain -z --untracked-files=all --ignore-submodules=none --no-renames
}

qr_noise_patch() {
  git -c core.filemode=true diff --binary --no-ext-diff --no-textconv --no-color --no-renames \
    --no-relative --src-prefix=a/ --dst-prefix=b/ --ignore-submodules=none HEAD --
}
