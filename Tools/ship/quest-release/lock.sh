# shellcheck shell=bash
# quest-release's single-run lock: `all`, `prepare`, `gate`, `build`, `verify`, `install`, `launch`, `rollback` and
# `cleanup` hold
# $QR_LOGS/run.lock (made with mkdir, so only one run gets it) with the run's PID and run folder, and release it on
# exit. Liveness checks the owner PID, step group and registered isolated groups, never process names. Sourced by
# Tools/ship/quest-release.sh; bash 3.2 compatible.

# Device-step wrapper uses the same race-safe lock primitives below.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/device-lock.sh"

qr_lock_dir() { printf '%s/run.lock\n' "$QR_LOGS"; }

# Portable fractional epoch mtime; empty when missing.
qr_lock_mtime() { perl -MTime::HiRes=stat -e '@s = stat $ARGV[0]; print "$s[9]\n" if @s' "$1"; }

# The lock's PID and run folder into QR_LOCK_PID / QR_LOCK_RUN. Returns 0 while its owner or worker group lives,
# 1 when there is no lock, 2 when it is stale. An unknown group status is treated as live.
# A lock with no PID counts as alive for its first minute
# (another run is writing it), stale after that. For wait, status 1 can
# still carry generation evidence (FD 18 pins the directory when available).
qr_lock_read() {
  local d group status=0 workers="" metadata retry_evidence="" attempt stamp retry_stamp; d="${QR_LOCK_READ_DIR:-$(qr_lock_dir)}"
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  QR_LOCK_PID=""; QR_LOCK_RUN=""; QR_LOCK_INVOCATION=""
  QR_LOCK_POINTER_AT=""; QR_LOCK_PREV_PID=""; QR_LOCK_PREV_INVOCATION=""
  QR_LOCK_UNPUBLISHED_AT=""; QR_LOCK_UNPUBLISHED_ID=""
  if [ "${QR_WAIT_SAMPLE:-}" = 1 ]; then exec 18<&-; fi
  for attempt in 1 2; do
    status=0; metadata=""
    if [ "${QR_WAIT_SAMPLE:-}" = 1 ]; then
      # Isolate cd: cleanup can remove the waiter's original directory.
      # Keep the descriptor for the last sample that supplied evidence.
      if { exec 20< "$d"; } 2>/dev/null; then
        metadata="$(cd "$d" 2>/dev/null && qr_lock_snapshot "$d" pinned)" || status=$?
        if [ -n "$metadata" ]; then
          stamp="${metadata##*$'\n'}"
          retry_stamp="${retry_evidence##*$'\n'}"
          if [[ "$metadata" = $'\n'* && "$stamp" != *' unpinned' ]] &&
             [ "${stamp#* }" = "${retry_stamp#* }" ]; then
            # FD 18 still pins the first sample, so equality proves this is
            # the same lock. Keep a sampled owner or the earlier pending cutoff.
            if [[ "$retry_evidence" = [1-9]* ]]; then
              status=1; metadata="$retry_evidence"
            elif [ -n "$retry_evidence" ] &&
                 perl -e 'exit !($ARGV[0] < $ARGV[1])' "${retry_stamp% *}" "${stamp% *}"; then
              metadata="${metadata%$'\n'*}"$'\n'"$retry_stamp"
            fi
          fi
          case "$stamp" in
            *' unpinned') exec 18<&- ;;
            *) exec 18<&20 ;;
          esac
          if [ "$status" = 3 ]; then retry_evidence="$metadata"; fi
        fi
        exec 20<&-
      else
        status=1
      fi
    else
      metadata="$(qr_lock_snapshot "$d")" || status=$?
    fi
    # A generation removed during the read may have lost some of its files.
    # Retry for a complete sample, keeping generation evidence if it vanished.
    [ "$status" = 3 ] || break
  done
  if [ "$status" != 0 ]; then
    [ -n "$retry_evidence" ] || return 1
    metadata="$retry_evidence"
  fi
  {
    IFS= read -r QR_LOCK_PID
    IFS= read -r QR_LOCK_INVOCATION
    IFS= read -r group
    IFS= read -r QR_LOCK_RUN
    IFS= read -r workers || true
    read -r QR_LOCK_POINTER_AT QR_LOCK_PREV_PID QR_LOCK_PREV_INVOCATION || true
    read -r QR_LOCK_UNPUBLISHED_AT QR_LOCK_UNPUBLISHED_ID || true
  } <<< "$metadata"
  [ "$status" = 0 ] || return 1
  QR_LOCK_RUN="${QR_LOCK_RUN:--}"
  [ "$workers" != busy ] || return 0
  case "$group" in
    ''|0|*[!0-9]*) ;;
    *) qr_group_alive "$group" || status=$?
       [ "$status" = 1 ] || return 0 ;;
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

# Emit mtime and device:inode together, from the sampled directory or an open descriptor.
qr_lock_stamp() {
  perl -MTime::HiRes=stat -e 'my @s = @ARGV ? stat($ARGV[0]) : stat(*STDIN); print "$s[9] $s[0]:$s[1]\n" if @s' "$@"
}

# Bind the pointer's timestamp to the identity read from that same file.
qr_lock_pointer() {
  perl -MTime::HiRes=stat -e '
    open my $f, "<", $ARGV[0] or exit;
    my @s = stat $f; my $line = <$f>;
    print "$s[9] $line" if @s && defined $line;
  ' "$1"
}

# Pin the directory generation while sampling it. Status 3 means retry;
# its only possible output is evidence of an incomplete sample.
qr_lock_snapshot() {
  local pid group invocation run_dir workers="" previous="" unpublished_at="" stamp="" pid_arrived="" replaced=""
  local pointer="${1%/*}/current-invocation" pid_at="" pid_lost="" pointer_pid="" pointer_key="" pointer_at=""
  local published_pid published_key
  if [ "${2:-}" != pinned ]; then cd "$1" 2>/dev/null || return 1; fi
  # Sample the entered directory before PID/metadata reads. If pathname
  # replacement made FD 20 pin its predecessor, only use this directory's
  # stamp, and keep it as pending evidence rather than trusting its owner data.
  if [ "${QR_WAIT_SAMPLE:-}" = 1 ]; then
    local pinned_stamp
    stamp="$(qr_lock_stamp .)"
    [ -n "$stamp" ] || return 3
    pinned_stamp="$(qr_lock_stamp <&20)"
    if [ "${stamp#* }" != "${pinned_stamp#* }" ]; then
      replaced=1; stamp="${stamp% *} unpinned"
    elif [ -f pid ]; then
      pid_at="$(qr_lock_mtime pid)"
      # Sample a possible teardown pointer while the PID file still
      # provides an ordering check against the same directory generation.
      if [ "${1##*/}" = run.lock ] && [ -n "$pid_at" ]; then
        read -r pointer_at pointer_pid pointer_key <<< "$(qr_lock_pointer "$pointer")"
        [ "$1" -ef . ] || pointer_key=""
      fi
    fi
  fi
  pid="$(cat pid 2>/dev/null)"
  [ -z "$replaced" ] || [ -z "$pid" ] || return 3
  # Check the owner before sampling the step group: a live owner can still
  # publish a new step. Then check the step before walking its worker slots.
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then workers=busy; fi
  group="$(cat group 2>/dev/null)"
  invocation="$(cat invocation 2>/dev/null)"
  if [ -z "$invocation" ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    # Older producers could unlink invocation before removing the directory.
    # A keyed producer publishes its pointer after pid. An older pointer isn't
    # evidence for this lock (a genuine legacy owner may reuse the same PID).
    if [ -f pid ] && [ "${1##*/}" = run.lock ] && [ -f "$pointer" ] && [ ! pid -nt "$pointer" ] &&
       read -r published_pid published_key < "$pointer" && [ "$published_pid" = "$pid" ] &&
       [[ "$published_key" =~ ^run\.[a-zA-Z0-9]{10}$ ]]; then
      invocation="$published_key"
    fi
    if [ ! -f pid ]; then
      [ -n "$stamp" ] || return 3
      pid_lost=1
    fi
  fi
  if [ "${QR_WAIT_SAMPLE:-}" = 1 ] && [ -z "$pid" ]; then
    # A legacy writer can leave an empty pid file while publishing it. Retry
    # only if PID data actually appeared after the first read.
    unpublished_at="$stamp"
    previous="$(qr_lock_pointer "$pointer")"
    pid_arrived="$(cat pid 2>/dev/null)"
  fi
  run_dir="$(cat run_dir 2>/dev/null)"
  if [ "$workers" = busy ] || qr_lock_workers_busy "$group"; then workers=busy; fi
  if [ -n "$replaced$pid_arrived$pid_lost" ] || [ ! "$1" -ef . ]; then
    if [ -n "$stamp" ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      # The PID came from the pinned generation, even if teardown has now
      # removed its files. Use its captured cutoff, not a new pathname stat.
      if [ -z "$invocation" ] && [ -n "$pid_at" ] && [ "$pointer_pid" = "$pid" ] &&
         [[ "$pointer_key" =~ ^run\.[a-zA-Z0-9]{10}$ ]] &&
         perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$pointer_at" "$pid_at"; then
        invocation="$pointer_key"
      fi
      printf '%s\n%s\n\n%s\n\n%s\n%s\n' "$pid" "$invocation" "$run_dir" "$previous" "${pid_at:-${stamp% *}} ${stamp#* }"
    elif [ -n "$unpublished_at" ]; then
      # A pending sample has no owner to pin; keep its generation boundary.
      printf '\n%s\n\n\n\n%s\n%s\n' "$invocation" "$previous" "$unpublished_at"
    fi
    return 3
  fi
  printf '%s\n' "$pid" "$invocation" "$group" "$run_dir" "$workers" "$previous" "$unpublished_at"
}

# Only look at the worker tree in this pinned generation. Probe the step
# before expanding its slots; a worker could be authorized right up to exit.
qr_lock_workers_busy() {
  local step status=0
  for step in ./step.*; do
    [ -d "$step" ] || continue
    case "$1" in ''|0|*[!0-9]*) ;; *)
      qr_group_alive "$1" || status=$?
      [ "$status" = 1 ] || return 0 ;;
    esac
    qr_workers_busy "$step" && return 0
  done
  return 1
}

# Take the lock for the caller (normally $$), or refuse at once when a live run holds it. A stale lock is removed (logged).
qr_lock_acquire() {
  local d st _ publish="${1:-1}" owner_pid="${2:-$$}" invocation_dir
  d="$(qr_lock_dir)"
  for _ in 1 2; do
    if mkdir "$d" 2>/dev/null; then
      QR_INVOCATION=""
      if ! { { [ "$publish" = 0 ] ||
               { mkdir -p "$QR_LOGS/invocations" &&
                 invocation_dir="$(mktemp -d "$QR_LOGS/invocations/run.XXXXXXXXXX")" &&
                 QR_INVOCATION="${invocation_dir##*/}" &&
                 printf '%s\n' "$QR_INVOCATION" > "$d/invocation"; }; } &&
             printf '%s\n' "${QR_RUN_DIR:-pending}" > "$d/run_dir" &&
             # Publish pid last, atomically: wait must not pin a partial PID or miss its invocation key.
             [ ! -d "$d/pid" ] && printf '%s\n' "$owner_pid" > "$d/pid.tmp" && mv -f "$d/pid.tmp" "$d/pid" &&
             { [ "$publish" = 0 ] ||
               { printf '%s %s\n' "$$" "$QR_INVOCATION" > "$QR_LOGS/current-invocation.$$" &&
                 mv -f "$QR_LOGS/current-invocation.$$" "$QR_LOGS/current-invocation"; }; }; }; then
        qr_log "error: cannot write lock metadata in $d"
        rm -rf "$d"
        return 1
      fi
      QR_CANCEL_DISARMED=""
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

# Publish before unlocking. Freeze both the verdict and its report: even a
# successor in the same run folder cannot change what a pinned waiter sees.
# $3 is 0 for a single-command summary, 1 for an aggregate, absent for early failures.
qr_lock_result() {
  [ "${QR_LOCK_HELD:-}" = 1 ] || return 0
  local result="$QR_LOGS/last-result" verdict=1 report=""
  if [ -n "${QR_INVOCATION:-}" ]; then result="$QR_LOGS/invocations/$QR_INVOCATION/result"; fi
  if [ -n "${3:-}" ] && [ -n "${QR_RUN_DIR:-}" ] && [ -f "$QR_RUN_DIR/summary.txt" ]; then
    report="$QR_RUN_DIR/summary.txt"
    if [ "$2" = 0 ] && { [ "$3" = 1 ] || qr_wait_verdict "$QR_RUN_DIR" "$1"; }; then verdict=0; fi
  fi
  (
    printf 'pid=%s\ncmd=%s\nrc=%s\nrun=%s\nverdict=%s\nreport:\n' "$$" "$1" "$2" "${QR_RUN_DIR:-}" "$verdict" || exit 1
    if [ -n "$report" ]; then cat "$report" || exit 1; fi
  ) > "$result.tmp" && mv -f "$result.tmp" "$result" || return 1
  if [ -n "${QR_INVOCATION:-}" ]; then
    if ! { cp "$result" "$QR_LOGS/last-result.$$" && mv -f "$QR_LOGS/last-result.$$" "$QR_LOGS/last-result"; }; then
      rm -f "$QR_LOGS/last-result.$$" || true
      # The keyed result is already authoritative. Do not change the exit status.
      qr_log "warning: cannot update compatibility last-result in $QR_LOGS" || true
    fi
  fi
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
  step="$(cd "$step" && pwd)" || return 1
  case "$-" in *m*) monitor=1 ;; esac
  # Traps may run between the async launch and $! registration. Record cancellation there, then handle it
  # only once the group is discoverable. Do not ignore signals: the child must inherit normal dispositions.
  QR_REGISTERING_STEP=1
  QR_ACTIVE_STEP_DIR="$step"
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
    QR_STEP_DIR="$step" QR_WORKER_ROOT="$QR_ACTIVE_STEP_DIR" "$@"
  ) &
  if ! { printf '%s\n' "$!" > "$d/group" && touch "$step/ready"; }; then
    rc=1
  fi
  QR_ACTIVE_STEP=$!
  QR_REGISTERING_STEP=""
  [ -n "$monitor" ] || set +m
  [ -z "${QR_PENDING_CANCEL:-}" ] || qr_cancel "$cmd" "$QR_PENDING_CANCEL"
  if [ "$rc" = 0 ]; then wait "$QR_ACTIVE_STEP" || rc=$?; fi
  # Drain the step first to stop new registrations, then its isolated workers.
  qr_lock_drain_step || return 1
  rm -f "$d/group" || return 1
  return "$rc"
}

# Async editor/watchdog jobs can inherit ignored INT; always terminate with TERM. Resume stopped credential
# helpers so TERM can take effect, then escalate after a bounded grace period. Reap our direct child only after
# escalation, since an unbounded wait first would hang on a TERM-ignoring child.
qr_drain_group() {
  local group="$1" deadline=$((SECONDS + 2))
  kill -TERM -- "-$group" 2>/dev/null || true
  kill -CONT -- "-$group" 2>/dev/null || true
  while qr_own_group_alive "$group"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      qr_group_escalate "$group" || return 1
      break
    fi
    sleep 0.1
  done
  wait "$group" 2>/dev/null || true
}

qr_lock_drain_step() {
  qr_drain_group "$QR_ACTIVE_STEP" || return 1
  qr_workers_drain "$QR_ACTIVE_STEP_DIR" || return 1
  rm -rf "$QR_ACTIVE_STEP_DIR" || return 1
  QR_ACTIVE_STEP=""; QR_ACTIVE_STEP_DIR=""
}

# Cancel and drain before publishing failure. During launch+registration, defer rather than lose the new job.
qr_cancel() {
  [ "${QR_CANCEL_DISARMED:-}" != 1 ] || return 0
  local cmd="$1" signal="$2" group="${QR_ACTIVE_STEP:-}"
  if [ "${QR_REGISTERING_STEP:-}" = 1 ]; then QR_PENDING_CANCEL="$signal"; return; fi
  trap '' HUP INT TERM
  if [ -n "$group" ]; then
    # Perf recovery still needs the old group ID to resume its device lock.
    if ! qr_lock_drain_step; then
      [ "$cmd" != perf ] || qr_perf_cancel warn-only
      qr_lock_result "$cmd" 1
      exit 1
    fi
  fi
  if [ "$cmd" = perf ] || [ -f "$(qr_state_file)" ]; then qr_load_state; fi
  [ "$cmd" != perf ] || qr_perf_cancel
  # The worker may already be drained and its rows complete. Cancellation
  # still invalidates the overall verdict for this invocation, not those rows.
  if [ "${list_release:-0}" = 1 ] && [ "$(qr_get multi_command '')" = "$cmd" ]; then
    qr_multi_collect
    qr_set multi_result 3
    qr_set overall 'INFRA: cancelled'
  fi
  qr_summary
  qr_lock_result "$cmd" 1 0
  exit 1
}

# Remove the lock only when this process holds it.
qr_lock_release() {
  [ "${QR_LOCK_HELD:-}" = 1 ] || return 0
  local d retired; d="$(qr_lock_dir)"
  # A failed/interrupted drain must never drop the only record of a survivor.
  [ -z "${QR_ACTIVE_STEP:-}" ] || [ ! "${QR_ACTIVE_STEP_DIR%/*}" -ef "$d" ] || return 1
  # The result is final once unlock begins. A successor can change current.env
  # and the summary as soon as the rename completes, even before mv returns.
  QR_CANCEL_DISARMED=1
  if [ "$(cat "$d/pid" 2>/dev/null)" = "${1:-$$}" ]; then
    # Unpublish before deleting any fields, so a partial deletion is never
    # visible as an intact but legacy lock.
    retired="$d.released.$$"
    [ ! -e "$retired" ] && mv "$d" "$retired" || return 1
    rm -rf "$retired"
  fi
  QR_LOCK_HELD=""
}
