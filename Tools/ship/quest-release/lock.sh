# shellcheck shell=bash
# quest-release's single-run lock: `all`, `prepare`, `gate`, `build`, `verify`, `install`, `launch`, `rollback` and
# `cleanup` hold
# $QR_LOGS/run.lock (made with mkdir, so only one run gets it) with the run's PID and run folder, and release it on
# exit. Liveness checks the owner PID and the recorded worker process group, never process names. Sourced by
# Tools/ship/quest-release.sh; bash 3.2 compatible.

# Device-step wrapper uses the same race-safe lock primitives below.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/device-lock.sh"

qr_lock_dir() { printf '%s/run.lock\n' "$QR_LOGS"; }

# The lock's PID and run folder into QR_LOCK_PID / QR_LOCK_RUN. Returns 0 while its owner or worker group lives,
# 1 when there is no lock, 2 when it is stale. A lock with no PID counts as alive for its first minute
# (another run is writing it), stale after that.
qr_lock_read() {
  local d group; d="${QR_LOCK_READ_DIR:-$(qr_lock_dir)}"
  QR_LOCK_PID=""; QR_LOCK_RUN=""
  [ -d "$d" ] || return 1
  QR_LOCK_PID="$(cat "$d/pid" 2>/dev/null)"
  QR_LOCK_RUN="$(cat "$d/run_dir" 2>/dev/null)"
  QR_LOCK_RUN="${QR_LOCK_RUN:--}"
  group="$(cat "$d/group" 2>/dev/null)"
  case "$group" in
    ''|0|*[!0-9]*) ;;
    *) qr_group_alive "$group" && return 0 ;;
  esac
  case "$QR_LOCK_PID" in
    ''|*[!0-9]*)
      QR_LOCK_PID="${QR_LOCK_PID:-unknown}"
      # Reclamation's claim changes the directory mtime. Only a reclaimer pinned to this generation may
      # supply the stale age it observed before creating that claim; still recheck PID/group liveness.
      [ "${QR_LOCK_STALE_AGE:-}" = 1 ] || [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 0
      return 2 ;;
  esac
  kill -0 "$QR_LOCK_PID" 2>/dev/null && return 0
  return 2
}

# Take the lock for this process ($$), or refuse at once when a live run holds it. A stale lock is removed (logged).
qr_lock_acquire() {
  local d st _
  d="$(qr_lock_dir)"
  for _ in 1 2; do
    if mkdir "$d" 2>/dev/null; then
      if ! { printf '%s\n' "$$" > "$d/pid" &&
             printf '%s\n' "${QR_RUN_DIR:-pending}" > "$d/run_dir" &&
             printf '%s\n' "$$" > "$QR_LOGS/current-invocation.$$" &&
             mv -f "$QR_LOGS/current-invocation.$$" "$QR_LOGS/current-invocation"; }; then
        qr_log "error: cannot write lock metadata in $d"
        rm -rf "$d"
        return 1
      fi
      QR_LOCK_HELD=1
      return 0
    fi
    st=0; qr_lock_read || st=$?
    case "$st" in
      0) qr_log "error: another quest-release run is active (pid $QR_LOCK_PID, run folder $QR_LOCK_RUN)"; return 1 ;;
      2) qr_lock_reclaim "$d" || return 1 ;;
    esac
  done
  qr_log "error: cannot take the lock $d"
  return 1
}

# Serialize stale reclaimers inside the generation they are reclaiming, then re-read its metadata. A reader
# paused before claiming may now be looking at a live successor. Move the claimed directory intact before
# deleting it: removing the claim first would reopen the same race. An interrupted reclaimer fails closed
# (its claim must be inspected/removed manually), rather than risking deletion of a replacement lock.
qr_lock_reclaim() {
  local d="$1"
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  (
    # Pin this generation before claiming: a pathname alone can now name a different run's directory.
    cd "$d" || exit 1
    local aged=""
    [ -z "$(find . -maxdepth 0 -mmin +1 2>/dev/null)" ] || aged=1
    if ! mkdir reclaim 2>/dev/null; then
      qr_log "error: lock reclamation is already claimed ($d/reclaim)"
      exit 1
    fi
    local st=0
    QR_LOCK_READ_DIR=. QR_LOCK_STALE_AGE="$aged" qr_lock_read || st=$?
    if [ "$st" != 2 ]; then
      rmdir reclaim 2>/dev/null || true
      qr_log "error: another quest-release run is active (pid $QR_LOCK_PID, run folder $QR_LOCK_RUN)"
      exit 1
    fi
    if [ ! "$d" -ef . ]; then rmdir reclaim 2>/dev/null || true; exit 1; fi
    qr_log "removing a stale lock $d (pid $QR_LOCK_PID is gone, run folder $QR_LOCK_RUN)"
    # Destination is unique to this reclaimer; never move into an existing directory.
    [ ! -e "$d.reaped.$$" ] || exit 1
    mv "$d" "$d.reaped.$$" || exit 1
    rm -rf "$d.reaped.$$"
  )
}

# Record the run folder once prepare / the loaded state knows it.
qr_lock_note_run() {
  [ "${QR_LOCK_HELD:-}" = 1 ] && [ -n "${QR_RUN_DIR:-}" ] || return 0
  printf '%s\n' "$QR_RUN_DIR" > "$(qr_lock_dir)/run_dir" 2>/dev/null || true
}

# This invocation's terminal result for `wait`: $QR_LOGS/last-result (pid, cmd, rc, run folder), written (atomically)
# while the lock is still held, so `wait` judges the run it watched by that run's own exit status, never an older
# run's summary.
qr_lock_result() {
  [ "${QR_LOCK_HELD:-}" = 1 ] || return 0
  printf 'pid=%s\ncmd=%s\nrc=%s\nrun=%s\n' "$$" "$1" "$2" "${QR_RUN_DIR:-}" > "$QR_LOGS/last-result.$$" \
    && mv -f "$QR_LOGS/last-result.$$" "$QR_LOGS/last-result"
}

# Run the foreground step as a job in its own process group. Bash handles a trapped signal promptly while in
# `wait`, unlike a foreground subshell. Disable monitor mode inside it so nested editors, gate/build jobs and
# watchdogs stay in that same group. Preserve the caller's job-control setting (stock macOS Bash supported).
qr_run_step() {
  local rc=0 monitor="" d step
  d="$(qr_lock_dir)"
  # A unique per-step generation prevents an unpublished orphan from accepting a successor's go-ahead.
  # Even if the owner dies before group publication, no later step will reuse this readiness path.
  step="$(mktemp -d "$d/step.XXXXXXXXXX")" || return 1
  case "$-" in *m*) monitor=1 ;; esac
  # Traps may run between the async launch and $! registration. Record cancellation there, then handle it
  # only once the group is discoverable. Do not ignore signals: the child must inherit normal dispositions.
  QR_REGISTERING_STEP=1
  set -m
  (
    set +m; trap - HUP INT TERM
    while [ ! -f "$step/ready" ]; do
      kill -0 "$$" 2>/dev/null || exit 1
      [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] || exit 1
      sleep 0.05
    done
    # Readiness is authorization, not merely a scheduling hint: recheck ownership and liveness even when
    # it already exists on the child's first timeslice. Bash's $$ remains the lock owner in this subshell.
    kill -0 "$$" 2>/dev/null || exit 1
    [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] || exit 1
    QR_STEP_GROUP=1; "$@"
  ) &
  if ! { printf '%s\n' "$!" > "$d/group" && touch "$step/ready"; }; then
    rc=1
  fi
  QR_ACTIVE_STEP=$!
  QR_REGISTERING_STEP=""
  [ -n "$monitor" ] || set +m
  [ -z "${QR_PENDING_CANCEL:-}" ] || qr_cancel "$cmd" "$QR_PENDING_CANCEL"
  if [ "$rc" != 0 ]; then
    qr_drain_group "$QR_ACTIVE_STEP"
    QR_ACTIVE_STEP=""
    return 1
  fi
  wait "$QR_ACTIVE_STEP" || rc=$?
  # timeout --foreground kills only the editor. Drain compiler/Gradle descendants on normal step completion
  # too, before the owner publishes last-result or releases its lock (including failed builds inside all).
  qr_drain_group "$QR_ACTIVE_STEP"
  rm -f "$d/group"
  rm -rf "$step"
  QR_ACTIVE_STEP=""
  return "$rc"
}

# ps uses a numeric process-group identity only, never a process-name search. Zombies have already terminated.
qr_group_alive() {
  ps -axo pgid=,stat= | awk -v group="$1" '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }'
}

# Async editor/watchdog jobs can inherit ignored INT; always terminate with TERM. Resume stopped credential
# helpers so TERM can take effect, then escalate after a bounded grace period. Reap our direct child only after
# escalation, since an unbounded wait first would hang on a TERM-ignoring child.
qr_drain_group() {
  local group="$1" deadline=$((SECONDS + 2))
  kill -TERM -- "-$group" 2>/dev/null || true
  kill -CONT -- "-$group" 2>/dev/null || true
  while qr_group_alive "$group"; do
    if [ "$SECONDS" -ge "$deadline" ]; then kill -KILL -- "-$group" 2>/dev/null || true; fi
    sleep 0.1
  done
  wait "$group" 2>/dev/null || true
}

# Cancel and drain before publishing failure. During launch+registration, defer rather than lose the new job.
qr_cancel() {
  local cmd="$1" signal="$2" group="${QR_ACTIVE_STEP:-}"
  if [ "${QR_REGISTERING_STEP:-}" = 1 ]; then QR_PENDING_CANCEL="$signal"; return; fi
  trap '' HUP INT TERM
  if [ -n "$group" ]; then
    qr_drain_group "$group"
    QR_ACTIVE_STEP=""
  fi
  [ ! -f "$(qr_state_file)" ] || qr_load_state
  [ "$cmd" != perf ] || qr_perf_cancel
  qr_summary
  qr_lock_result "$cmd" 1
  exit 1
}

# Remove the lock only when this process holds it.
qr_lock_release() {
  [ "${QR_LOCK_HELD:-}" = 1 ] || return 0
  local d; d="$(qr_lock_dir)"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] && rm -rf "$d"
  QR_LOCK_HELD=""
}
