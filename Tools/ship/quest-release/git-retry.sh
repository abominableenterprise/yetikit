# shellcheck shell=bash
# Run Git from the consumer repository. Only network subcommands are retryable.
qr_git() {
  case "${1:-}" in
    fetch|pull|ls-remote) qr_git_retry "$@" ;;
    *) git -C "$QR_REPO" "$@" ;;
  esac
}

qr_git_transient() {
  # Match transport diagnostics, not generic Git failures such as exit 128,
  # "early EOF", or "Could not read from remote repository" (also used for auth).
  LC_ALL=C grep -Eiq \
    -e '^(fatal: unable to access .*: |ssh: connect to host .* port [0-9]+: |(fatal: )?(ssh: )?(read|write): ).*(timed out|timeout|connection reset by peer|connection refused|temporary failure in name resolution)$' \
    -e '^fatal: unable to access .*: could not resolve (host|proxy): ' \
    -e '^ssh: could not resolve hostname .*: (temporary failure in name resolution|try again)$' \
    -e '^(fatal: unable to access .*: |error: RPC failed; )The requested URL returned error: (502|503|504)$' \
    -e '^error: RPC failed; curl (18|28|52|55|56) ' "$1"
}

qr_git_retry() (
  local scratch attempt rc=0
  scratch="$(mktemp -d)" || return 1
  trap 'rm -rf "$scratch"' EXIT
  trap 'exit 143' HUP INT TERM
  for attempt in 1 2 3; do
    rc=0
    LC_ALL=C git -C "$QR_REPO" "$@" > "$scratch/out" 2> "$scratch/err" || rc=$?
    if [ "$rc" = 0 ] || ! qr_git_transient "$scratch/err"; then break; fi
    if [ "$attempt" = 3 ]; then
      echo "git $1: transient network failure after $attempt attempts" >&2
      break
    fi
    echo "git $1: transient network failure (attempt $attempt/3); retrying in ${attempt}s" >&2
    sleep "$attempt" || return 1
  done
  # Discard partial results from abandoned attempts, especially ls-remote's refs.
  cat "$scratch/out"
  cat "$scratch/err" >&2
  return "$rc"
)
