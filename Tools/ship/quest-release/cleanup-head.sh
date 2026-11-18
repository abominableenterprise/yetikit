# shellcheck shell=bash
# Use Git's own ref transaction so ordinary HEAD writers contend on the same
# lock. A verify-only transaction never changes HEAD or its reflog.
qr_with_cleanup_head() (
  local wt="$1" scratch started prepared rc
  shift
  qr_registered_worktree "$wt" || return 1
  scratch="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$scratch"' EXIT
  mkfifo "$scratch/replies" || return 1
  # The pipeline is the request channel; the FIFO returns Git's acknowledgments.
  # Keep stdin open until the action finishes, then reap Git before returning.
  set -o pipefail
  {
    (
      printf 'start\noption no-deref\nverify HEAD %s\nprepare\n' "$QR_SHA" || exit 1
      IFS= read -r started && [ "$started" = 'start: ok' ] &&
        IFS= read -r prepared && [ "$prepared" = 'prepare: ok' ] || exit 1
      # A symbolic HEAD can resolve to the same SHA. Check detachment while
      # the transaction holds the ref lock, not just before acquiring it.
      qr_cleanup_expected_head "$wt" || exit 1
      rc=0
      "$@" </dev/null >&3 3>&- || rc=$?
      # Close stdin with an open transaction: Git aborts and releases it.
      exit "$rc"
    ) < "$scratch/replies" | git -C "$wt" update-ref --stdin > "$scratch/replies" 2>> "$QR_RUN_DIR/cleanup.log"
  } 3>&1
)
