# shellcheck shell=bash
qr_discard_noise() { qr_inspect_noise "$1" discard; }
qr_check_release_noise() { qr_inspect_noise "$1" check "${2:-}"; }

# Share the classifier and index checks, but only opt-in cleanup reverses edits.
qr_inspect_noise() (
  local wt="$1" action="$2" apk="${3:-}" scratch record path reason
  if ! qr_registered_worktree "$wt"; then
    qr_log "$wt is not the registered release worktree"
    return 2
  fi
  cd -P -- "$wt" || return 2
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
  if [ "$action" = check ]; then
    # Ignore only known Unity output trees, not arbitrary project/global ignore
    # rules (which could hide a new script or asset). Directory patterns do
    # not also hide symlinks at these paths.
    git ls-files -z --others --exclude=/Library/ --exclude=/Temp/ --exclude=/Obj/ \
      --exclude=/Logs/ --exclude=/UserSettings/ > "$scratch/untracked" || return 2
    while IFS= read -r -d '' path; do
      # The build replaces this exact output, not all files under Builds/.
      case "$path" in
        *.apk) if [ "$path" = "$apk" ] && [ -f "$path" ] && [ ! -L "$path" ]; then continue; fi ;;
      esac
      qr_log "unclassified untracked file in $wt: $path"
      return 1
    done < "$scratch/untracked"
    qr_noise_status --untracked-files=no > "$scratch/status" || return 2
  else
    qr_noise_status > "$scratch/status" || return 2
  fi
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
    # A configured font path alone is sufficient for opt-in cleanup, but
    # does not prove its contents are harmless for release provenance.
    if [ ! -f "$path" ] || [ -L "$path" ] ||
      { [ "$action" = check ] && noise_font_path "$path"; } ||
      ! reason="$(noise_run_reason "$path")"; then
      qr_log "keeping $wt: real changes or unclassified editor noise: $path"
      return 1
    fi
    qr_log "recognized editor noise in $wt: $path ($reason)"
  done < "$scratch/status"

  [ "$action" = discard ] || { [ -s "$scratch/patch" ] && qr_expected_worktree_head . "$QR_SHA"; return $?; }

  qr_with_cleanup_head "$PWD" qr_reverse_noise "$scratch" || return 2
)

# Under the HEAD lock, recheck the inspected patch and reverse only that patch.
# Let ordinary Git removal reject any remaining edits.
qr_reverse_noise() {
  local scratch="$1"
  qr_noise_status > "$scratch/current-status" && cmp -s "$scratch/status" "$scratch/current-status" &&
    qr_noise_patch > "$scratch/current-patch" && cmp -s "$scratch/patch" "$scratch/current-patch" || return 2
  [ -s "$scratch/patch" ] || return 2
  git -c apply.ignoreWhitespace=no apply --reverse --whitespace=nowarn "$scratch/patch"
}

qr_noise_status() {
  git -c core.filemode=true -c core.fsmonitor=false status --porcelain -z --untracked-files=all --ignore-submodules=none --no-renames "$@"
}

qr_noise_patch() {
  git -c core.filemode=true diff --binary --no-ext-diff --no-textconv --no-color --no-renames \
    --no-relative --src-prefix=a/ --dst-prefix=b/ --ignore-submodules=none HEAD --
}
