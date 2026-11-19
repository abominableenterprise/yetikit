# shellcheck shell=bash
# Each isolated group reserves a unique slot under its caller's group directory.
# Only the caller can publish the group (an atomic mkdir); the child cannot run
# the command first. Descendants register under that published group, not as
# siblings, so draining a parent group freezes registration at the next level.
qr_worker_slot() {
  [ -n "$1" ] || return 0
  mktemp -d "$1/worker.XXXXXXXXXX"
}

qr_worker_publish() {
  [ -z "$1" ] && return 0
  [[ "$2" =~ ^[1-9][0-9]*$ ]] && mkdir "$1/group.$2"
}

qr_worker_await() {
  local slot="$1" parent="$2" entry
  QR_WORKER_ROOT=""; export QR_WORKER_ROOT
  [ -n "$slot" ] || return 0
  while [ -d "$slot" ] && kill -0 "$parent" 2>/dev/null; do
    for entry in "$slot"/group.*; do
      if [ -d "$entry" ]; then QR_WORKER_ROOT="$entry"; return 0; fi
    done
    command sleep 0.05
  done
  return 1
}

# Orphaned device lock owners and wrappers can remain as zombies.
qr_lock_process_busy() {
  local state
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -p "$1" -o stat= 2>/dev/null)" || { kill -0 "$1" 2>/dev/null; return $?; }
  [[ "$state" != *Z* ]]
}

# KILL does not remove an unreaped zombie or guarantee immediate exit.
# Bound polling even if ps keeps failing and kill -0 still sees the group.
qr_group_escalate() {
  local pgid="$1" polls=20
  kill -KILL -- "-$pgid" 2>/dev/null || true
  while qr_own_group_alive "$pgid"; do
    if [ "$polls" -le 0 ]; then
      printf '[quest-release] error: cleanup failed: could not confirm exit of process group %s\n' "$pgid" >&2
      return 1
    fi
    polls=$((polls - 1))
    command sleep 0.1
  done
}

qr_worker_drain_group() {
  local pgid="$1" deadline=$((SECONDS + 2))
  qr_own_group_alive "$pgid" || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  kill -CONT -- "-$pgid" 2>/dev/null || true
  while qr_own_group_alive "$pgid"; do
    if [ "$SECONDS" -ge "$deadline" ]; then qr_group_escalate "$pgid"; return $?; fi
    command sleep 0.1
  done
}

# Read only after the enclosing group is gone. Unknown process status (or an
# invalid group record) is not proof of absence and cannot authorize reclaim.
qr_workers_busy() {
  local entry pgid status
  for entry in "$1"/worker.*/group.*; do
    [ -d "$entry" ] || continue
    pgid="${entry##*.}"
    [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 0
    status=0; qr_group_alive "$pgid" || status=$?
    [ "$status" = 1 ] || return 0
    qr_workers_busy "$entry" && return 0
  done
  return 1
}

# Drain only after the enclosing group is gone; it can no longer authorize a
# child. An unpublished slot can be discarded without signalling any process.
# Keep an unconfirmed slot intact, but it cannot authorize work in a sibling.
qr_workers_drain() {
  local slot entry pgid slot_failed rc=0
  for slot in "$1"/worker.*; do
    [ -d "$slot" ] || continue
    slot_failed=0
    for entry in "$slot"/group.*; do
      [ -d "$entry" ] || continue
      pgid="${entry##*.}"
      if ! { [[ "$pgid" =~ ^[1-9][0-9]*$ ]] && qr_worker_drain_group "$pgid" && qr_workers_drain "$entry"; }; then
        slot_failed=1
      fi
    done
    if [ "$slot_failed" = 1 ] || ! rm -rf "$slot"; then rc=1; fi
  done
  return "$rc"
}
