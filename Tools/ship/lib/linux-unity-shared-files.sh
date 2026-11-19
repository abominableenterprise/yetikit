#!/usr/bin/env bash
# Cleanup touches global shared memory, so serialize editor runs across checkouts
# and installations using that SHM_DIR. Refuse overlap instead of killing a peer.
lock_unity() {
  [ -z "${UNITY_CLEANUP_FD:-}" ] || return 0
  local lock="$SHM_DIR/.linux-unity-cleanup.lock" flock_args=(-n)
  # Publish once with shared read access, without truncating/replacing a peer's
  # inode. Linux flock can take an exclusive lock on a read-only descriptor.
  [ -e "$lock" ] || (umask 022; set -C; : > "$lock") 2>/dev/null || true
  exec {UNITY_CLEANUP_FD}< "$lock" || die "cannot read $lock; ensure all runner accounts have read access"
  [ "$#" = 0 ] || flock_args=(-w "$1")
  flock "${flock_args[@]}" "$UNITY_CLEANUP_FD" || die "another Unity run owns $SHM_DIR; wait for it or stop its checkout"
  chain_exit_trap 'exec {UNITY_CLEANUP_FD}>&-'
}

# Caller holds lock_unity. Never wipe shared files while a foreign editor may still own them.
wipe_unity_shared_files() {
  local remaining uid complete=0
  uid="$(id -u)" || return 1
  if [ "${1:-}" = require-idle ]; then
    # Setup already uses elevated inspection before replacing an installation.
    remaining="$(unity_pids_as_root strict shared-files)" && complete=1
  elif remaining="$(unity_pids strict shared-files)"; then
    complete=1
  elif [ "$uid" != 0 ] && [ -z "$remaining" ]; then
    # A UID mismatch alone cannot rule out a foreign editor. Ask for a fuller
    # process view if available without prompting; never elevate file removal.
    remaining="$(unity_pids_as_root --non-interactive strict shared-files 2>/dev/null)" && complete=1
  fi

  if [ "$complete" = 0 ]; then
    log "warning: Unity process inspection incomplete; skipping shared-memory and UnityLockfile cleanup"
  elif [ -n "$remaining" ]; then
    log "warning: Unity processes remain (PIDs:$remaining); skipping shared-memory and UnityLockfile cleanup"
  else
    remove_owned_unity_shared_files "$uid"
    return
  fi
  [ "${1:-}" != require-idle ]
}

remove_owned_unity_shared_files() {
  local uid="$1" path owner retained=0
  local -a owned=()
  for path in "$SHM_DIR"/udsMem* "$SHM_DIR"/sem.udsMem* "$PROJECT/Temp/UnityLockfile"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    if owner="$(stat -c %u -- "$path" 2>/dev/null)" && [ "$owner" = "$uid" ]; then
      owned+=("$path")
    else
      retained=1
    fi
  done
  if [ "$retained" = 1 ]; then
    log "warning: retaining shared-memory or UnityLockfile entries not verified as owned by UID $uid"
  fi
  [ "${#owned[@]}" = 0 ] || rm -f -- "${owned[@]}"
}
