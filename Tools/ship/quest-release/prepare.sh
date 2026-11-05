# shellcheck shell=bash
# quest-release `prepare [<ref>]` and `cleanup`: the two release worktrees (test, build) at one exact commit, each
# with its own Library cloned (APFS clone, /bin/cp -c) from the warm worktree. Sourced by Tools/ship/quest-release.sh.

# Free space in GB on the filesystem holding $1 (df -Pk: POSIX output on BSD and GNU alike).
qr_free_gb() { df -Pk "$1" | awk 'NR == 2 { printf "%d\n", $4 / 1048576 }'; }

qr_check_disk() {
  local free
  free="$(qr_free_gb "$1")"
  case "$free" in ''|*[!0-9]*) qr_die "cannot read free space for $1 from df" ;; esac
  [ "$free" -ge "$QR_MIN_FREE_GB" ] \
    || qr_die "only ${free} GB free on $1; prepare needs ${QR_MIN_FREE_GB} GB (two Library clones + an APK build)"
  qr_log "disk: ${free} GB free (need ${QR_MIN_FREE_GB})"
}

# git in the main repository (where this script lives).
qr_git() { git -C "$QR_REPO" "$@"; }

# APFS copy-on-write clone of directory $1 to $2: /bin/cp explicitly, as GNU coreutils' cp (no -c) may shadow it on PATH.
# A real directory, never a symlink: two editors must not share one Library.
qr_clone_dir() { /bin/cp -c -R "$1" "$2"; }

# Create worktree $1 detached at commit $2, with a Library cloned from the warm worktree.
qr_make_worktree() {
  local wt="$1" sha="$2" status
  if [ -e "$wt" ]; then
    [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$sha" ] || qr_die "$wt exists at another commit; run cleanup or remove it"
    status="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" \
      || qr_die "cannot inspect $wt; preserving worktree"
    [ -z "$status" ] || qr_die "$wt exists with local changes; run cleanup or remove it"
    qr_log "reusing clean worktree $wt"
  else
    qr_git worktree add --detach "$wt" "$sha" >> "$QR_RUN_DIR/prepare.log" 2>&1 || qr_die "git worktree add $wt failed (prepare.log)"
  fi
  [ ! -L "$wt/Library" ] || qr_die "$wt/Library is a symlink; refusing"
  if [ ! -d "$wt/Library" ]; then
    qr_log "cloning Library into $wt (APFS clone)"
    qr_clone_dir "$QR_WARM/Library" "$wt/Library" >> "$QR_RUN_DIR/prepare.log" 2>&1 \
      || qr_die "/bin/cp -c -R of $QR_WARM/Library failed (prepare.log)"
  fi
}

qr_prepare() {
  local ref="${1:-origin/main}" sha ssh_command ssh_wrapper ssh_prefixes=1 ssh_assignments="" env_bin
  local assignment_start='^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*=' i char quote
  rm -f "$(qr_state_file)" # a failed prepare must not leave the previous release as the current one
  { [ -d "$QR_WARM/Library" ] && [ ! -L "$QR_WARM/Library" ]; } || qr_die "no warm Library at $QR_WARM/Library (QUEST_WARM_WORKTREE)"
  mkdir -p "$QR_ROOT" "$QR_LOGS"
  qr_check_disk "$QR_ROOT"
  # Steps run in a background process group: a /dev/tty credential prompt would stop on SIGTTIN.
  # Match Git's precedence: command environment, repository config, executable environment, default.
  if [ "${GIT_SSH_COMMAND+x}" = x ]; then
    ssh_command="$GIT_SSH_COMMAND"
  elif ssh_command="$(qr_git config --get core.sshCommand)"; then
    :
  elif [ "${GIT_SSH+x}" = x ]; then
    # GIT_SSH is a literal executable path, not shell command text (unlike the two above).
    ssh_command="'${GIT_SSH//\'/\'\\\'\'}'"
    ssh_prefixes=0
  else
    ssh_command=ssh
  fi
  # Resolve before a transport-specific PATH assignment changes command lookup in Git's shell.
  env_bin="$(command -v env)"
  [[ "$env_bin" = /* ]] && [ -x "$env_bin" ] || qr_die "cannot resolve an absolute env executable"
  env_bin="'${env_bin//\'/\'\\\'\'}'" # quote the resolved path for Git's shell
  # Keep assignment-context expansion (notably unquoted ~/) in Git's shell. Scan quoted/escaped
  # fragments without evaluating anything. Nested shell expansions need a full shell parser;
  # reject them explicitly rather than splitting a word at whitespace inside an expansion.
  if [ "$ssh_prefixes" = 1 ]; then
    while [[ "$ssh_command" =~ $assignment_start ]]; do
      i=${#BASH_REMATCH[0]}; quote=""
      while [ "$i" -lt "${#ssh_command}" ]; do
        char="${ssh_command:i:1}"
        if [ "$quote" = "'" ]; then
          [ "$char" != "'" ] || quote=""
        else
          case "$char" in
            \\) i=$((i + 1)); [ "$i" -lt "${#ssh_command}" ] || qr_die "unsupported SSH assignment syntax: trailing escape" ;;
            '"') if [ "$quote" = '"' ]; then quote=""; else quote='"'; fi ;;
            "'") [ -n "$quote" ] || quote="'" ;;
            '$')
              case "${ssh_command:i+1:1}" in
                '{'|'(') qr_die "unsupported SSH assignment syntax: use a literal/quoted value or export expansions before prepare" ;;
              esac ;;
            '`') qr_die "unsupported SSH assignment syntax: export command substitutions before prepare" ;;
            [[:space:]]) [ -n "$quote" ] || break ;;
            '('|')'|'<'|'>'|'&'|'|'|';')
              [ -n "$quote" ] || qr_die "unsupported SSH assignment syntax: quote shell metacharacters" ;;
          esac
        fi
        i=$((i + 1))
      done
      [ -z "$quote" ] || qr_die "unsupported SSH assignment syntax: unterminated quote"
      ssh_assignments="$ssh_assignments${ssh_command:0:i} "
      ssh_command="${ssh_command:i}"
      # Normalize every separator accepted by the scanner, including newline command boundaries.
      while [[ "$ssh_command" = [[:space:]]* ]]; do ssh_command="${ssh_command:1}"; done
    done
  fi
  # Let Git's shell parse quoting; never eval the resulting arguments a second time. Rotate the
  # arguments once to insert before SSH's options, skipping env/NAME=value prefixes. Running the
  # result through env preserves assignments (including quoted values), rather than treating one
  # as the executable. OpenSSH takes the FIRST BatchMode value. GIT_SSH stays a literal executable.
  # This wrapper runs in Git's /bin/sh, so use only POSIX syntax (also works with macOS Bash 3.2).
  ssh_wrapper='qr_ssh() {
    qr_ssh_prefixes=$1; shift
    qr_ssh_left=$#
    qr_ssh_env=0
    qr_ssh_operand=0
    while [ "$qr_ssh_left" -gt 0 ]; do
      qr_ssh_arg=$1; shift
      qr_ssh_left=$((qr_ssh_left - 1))
      if [ "$qr_ssh_prefixes" = 1 ]; then
        if [ "$qr_ssh_operand" = 1 ]; then
          set -- "$@" "$qr_ssh_arg"
          qr_ssh_operand=0
          continue
        fi
        if [ "$qr_ssh_env" = 1 ]; then
          case "$qr_ssh_arg" in
            -u|--unset|-C|--chdir)
              set -- "$@" "$qr_ssh_arg"; qr_ssh_operand=1; continue ;;
            -i|--ignore-environment|-|--unset=*|--chdir=*|-u?*|-C?*)
              set -- "$@" "$qr_ssh_arg"; continue ;;
            --) set -- "$@" "$qr_ssh_arg"; qr_ssh_env=0; continue ;;
          esac
          qr_ssh_env=0
        fi
        case "$qr_ssh_arg" in
          *=*)
            qr_ssh_name=${qr_ssh_arg%%=*}
            case "$qr_ssh_name" in
              ""|[!a-zA-Z_]*|*[!a-zA-Z0-9_]*) ;;
              *) set -- "$@" "$qr_ssh_arg"; continue ;;
            esac ;;
          env|*/env) set -- "$@" "$qr_ssh_arg"; qr_ssh_env=1; continue ;;
        esac
      fi
      set -- "$@" "$qr_ssh_arg" -o BatchMode=yes
      # Rotate the remaining SSH arguments unchanged, then execute the reconstructed command.
      while [ "$qr_ssh_left" -gt 0 ]; do
        qr_ssh_arg=$1; shift
        set -- "$@" "$qr_ssh_arg"
        qr_ssh_left=$((qr_ssh_left - 1))
      done
      if [ "$qr_ssh_prefixes" = 1 ]; then
        '"$env_bin"' -- "$@"
      else
        "$@"
      fi
      return $?
    done
    return 127 # no executable: do not let bare env print the release environment
  }'
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_wrapper; ${ssh_assignments}qr_ssh $ssh_prefixes $ssh_command" \
    qr_git fetch --quiet origin || qr_die "git fetch origin failed (non-interactive): authenticate with git / load your SSH key into ssh-agent, then retry prepare"
  sha="$(qr_git rev-parse --verify --quiet "$ref^{commit}")" || qr_die "unknown ref $ref"
  qr_new_run "$sha" "$ref" pending
  qr_lock_note_run
  qr_set commit "${sha:0:9} ($ref)"
  qr_log "release $sha ($ref), run folder $QR_RUN_DIR"
  qr_make_worktree "$(qr_wt test)" "$sha"
  qr_make_worktree "$(qr_wt build)" "$sha"
  qr_publish_state
  qr_log "worktrees ready: $(qr_wt test), $(qr_wt build)"
}

# Unity re-save noise: the only changes cleanup may throw away.
qr_is_noise() {
  case "$1" in
    *.mat|*.asset|ProjectSettings/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Remove worktree $1 when every change in it is noise; otherwise keep it and print why.
qr_cleanup_one() {
  local wt="$1" kept="" record path original status_file
  [ -d "$wt" ] || { echo "absent"; return 0; }
  status_file="$(mktemp "${QR_RUN_DIR}/status.XXXXXX")" || { echo "inspection failed"; return 1; }
  if ! git -C "$wt" status --porcelain -z --untracked-files=all > "$status_file" 2>/dev/null; then
    rm -f "$status_file"
    qr_log "cannot inspect $wt; preserving worktree"
    echo "kept (inspection failed)"
    return 1
  fi
  # Porcelain -z places the destination first, then a second NUL-terminated source for renames/copies.
  # Check both sides: a staged source rename to an .asset is not disposable Unity noise.
  while IFS= read -r -d '' record; do
    path="${record:3}"
    qr_is_noise "$path" || kept="$kept $path"
    case "${record:0:2}" in
      *R*|*C*)
        IFS= read -r -d '' original || { rm -f "$status_file"; echo "kept (invalid status)"; return 1; }
        qr_is_noise "$original" || kept="$kept $original" ;;
    esac
  done < "$status_file"
  rm -f "$status_file"
  if [ -n "$kept" ]; then
    qr_log "keeping $wt: real changes:$kept"
    echo "kept (changed:$kept)"
    return 1
  fi
  if qr_git worktree remove --force "$wt" >> "$QR_RUN_DIR/cleanup.log" 2>&1; then
    echo "removed"
  else
    qr_log "git worktree remove $wt failed (cleanup.log)"; echo "remove failed"; return 1
  fi
}

qr_cleanup() {
  qr_need_commit
  local rc=0 t b
  t="$(qr_cleanup_one "$(qr_wt test)")" || rc=1
  b="$(qr_cleanup_one "$(qr_wt build)")" || rc=1
  qr_set cleanup "test $t; build $b"
  qr_log "cleanup: test $t; build $b"
  return "$rc"
}
