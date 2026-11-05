# shellcheck shell=bash
# Per-run Unity seat lease from The Robots hub (AGENTS.md: hub-secret-lease: per-run). Sourced by linux-unity.sh
# (needs its log, die, ULF, ulf_problem and OUT_DIR). Without THEROBOTS_HUB_URL, THEROBOTS_TASK_ID and
# THEROBOTS_TASK_TOKEN, or without Unity credentials (UNITY_USERNAME/UNITY_PASSWORD after linux-unity.sh's
# USERNAME/PASSWORD fallback), every function here is a no-op. Never prints the token.
#
# seat_acquire runs right before a licence activation (activate, the automatic re-activation, all) and waits for
# the hub's seat; cmd_return calls seat_release after a successful return. SEAT_STATE ("<task id> <pid>") records
# that this task holds the seat, so the later invocations (open, test, scene, return) know; the pid names the
# invocation that acquired it, for seat_exit. Successful activations persist until explicit/idle return.
SEAT_STATE="${SEAT_STATE:-$OUT_DIR/unity-seat.held}"
UNITY_SEAT_WAIT_MINUTES="${UNITY_SEAT_WAIT_MINUTES:-90}"

seat_env() { [ -n "${THEROBOTS_HUB_URL:-}" ] && [ -n "${THEROBOTS_TASK_ID:-}" ] && [ -n "${THEROBOTS_TASK_TOKEN:-}" ]; }
seat_creds() { [ -n "${UNITY_USERNAME:-}" ] && [ -n "${UNITY_PASSWORD:-}" ]; }
# Monotonic elapsed seconds, including time spent in slow hub requests.
seat_now() { awk '{print int($1)}' /proc/uptime; }
# Logs once per run why the seat is skipped; returns nonzero when it is (no credentials, or no hub task env).
seat_on() {
  if ! seat_creds; then
    [ -n "${SEAT_SKIP_LOGGED:-}" ] || log "seat: no Unity credentials, skipping"
    SEAT_SKIP_LOGGED=1; return 1
  fi
  if ! seat_env; then
    [ -n "${SEAT_SKIP_LOGGED:-}" ] || log "seat: no hub task env, skipping"
    SEAT_SKIP_LOGGED=1; return 1
  fi
}
seat_held() { [ -f "$SEAT_STATE" ] && [ "$(cut -d' ' -f1 "$SEAT_STATE")" = "$THEROBOTS_TASK_ID" ]; }

# POST {"action":"$1"} to the task's seat endpoint. Sets SEAT_CODE (HTTP code, 000 when curl failed), SEAT_BODY,
# SEAT_RETRY (Retry-After seconds, empty when absent) and SEAT_ERR (curl's error, token masked). The token reaches
# curl on stdin (-H @-), never on a command line.
seat_post() {
  local d; d="$(mktemp -d)"
  SEAT_CODE="$(printf 'Authorization: Bearer %s\n' "$THEROBOTS_TASK_TOKEN" | curl -sS -X POST --max-time 30 -H @- \
    -H 'Content-Type: application/json' -d "{\"action\":\"$1\"}" -D "$d/h" -o "$d/b" -w '%{http_code}' \
    "$THEROBOTS_HUB_URL/tasks/$THEROBOTS_TASK_ID/seat" 2>"$d/e")" || SEAT_CODE=000
  [[ "$SEAT_CODE" =~ ^[0-9]{3}$ ]] || SEAT_CODE=000
  SEAT_BODY="$(cat "$d/b" 2>/dev/null || true)"
  SEAT_RETRY="$(tr -d '\r' < "$d/h" 2>/dev/null | sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]: *\([0-9]\{1,4\}\) *$/\1/p' | tail -n1)" || true
  SEAT_ERR="$(head -c 300 "$d/e" 2>/dev/null | tr '\n' ' ')" || true
  SEAT_ERR="${SEAT_ERR//"$THEROBOTS_TASK_TOKEN"/<token>}"
  rm -rf "$d"
}

# The first 120 characters of SEAT_BODY on one line, token masked, for a log line.
seat_body_snippet() {
  local b="${SEAT_BODY//"$THEROBOTS_TASK_TOKEN"/<token>}"
  b="$(printf '%s' "$b" | tr -s '\r\n\t' '   ' | tr -cd '[:print:]' | sed 's/^ *//; s/ *$//')"
  b="${b:0:120}"; b="${b//"$THEROBOTS_TASK_TOKEN"/<token>}"
  printf '%s' "${b:-empty body}"
}

# Wait for the hub's Unity seat: 202 or 409 naming a race = still queued (poll after Retry-After, default 2 s,
# at most 10 s; one progress line per minute), 200 + "acquired" = Unity may start. 200 + "not_leased" and legacy
# 409s go on without a lease (no state file, no release); a 409 naming a cancelled/done task and any other code
# fail. Gives up after UNITY_SEAT_WAIT_MINUTES.
seat_acquire() {
  SEAT_REQUIRED=0  # no-lease compatibility paths do not require a marker
  seat_on || return 0
  SEAT_REQUIRED=1
  local unlock=0
  [ -n "${ACTIVATION_FD:-}" ] || unlock=1
  activation_lock
  idle_settle_own_retirement
  local held=0
  seat_held && held=1
  [ "$unlock" = 0 ] || activation_unlock
  if [ "$held" = 1 ]; then log "seat: this task already holds a Unity seat"; return 0; fi
  [[ "$UNITY_SEAT_WAIT_MINUTES" =~ ^[0-9]+$ ]] || die "seat: UNITY_SEAT_WAIT_MINUTES must be a whole number of minutes"
  local waited=0 start limit=$((10#$UNITY_SEAT_WAIT_MINUTES * 60)) shown=-1 delay marker
  start="$(seat_now)"
  SEAT_PENDING=1   # even a lost response may have granted a seat on the hub
  log "seat: acquiring a Unity seat from the hub"
  while :; do
    seat_post acquire
    case "$SEAT_CODE" in
      200) grep -q '"status" *: *"acquired"' <<< "$SEAT_BODY" && break
        if grep -q '"status" *: *"not_leased"' <<< "$SEAT_BODY"; then
          SEAT_PENDING=0; SEAT_REQUIRED=0
          log "seat: task is not seat-leased; continuing without a lease"; return 0
        fi
        die "seat: hub answered HTTP 200 without \"acquired\"" ;;
      202) ;;
      409) if grep -Eiq '\b(cancel|done|closed|closing|finished)' <<< "$SEAT_BODY"; then
          die "seat: the hub cancelled this task (HTTP 409: $(seat_body_snippet)); not activating Unity"
        fi
        if ! grep -qi 'race' <<< "$SEAT_BODY"; then
          SEAT_PENDING=0; SEAT_REQUIRED=0
          log "warning: seat: hub answered 409 ($(seat_body_snippet)); continuing without a lease"; return 0
        fi ;;
      *) die "seat: acquire failed (HTTP $SEAT_CODE)${SEAT_ERR:+: $SEAT_ERR}; not activating Unity" ;;
    esac
    waited=$(($(seat_now) - start))
    if [ "$waited" -ge "$limit" ]; then
      die "seat: no Unity seat after $UNITY_SEAT_WAIT_MINUTES min (UNITY_SEAT_WAIT_MINUTES); try again later"
    fi
    if [ $((waited / 60)) != "$shown" ]; then shown=$((waited / 60)); log "seat: waiting for a Unity seat ($shown min)"; fi
    delay="${SEAT_RETRY:-2}"; delay=$((10#$delay))
    [ "$delay" -ge 1 ] || delay=1
    [ "$delay" -le 10 ] || delay=10
    [ "$delay" -le "$((limit - waited))" ] || delay=$((limit - waited))
    sleep "$delay"
    if [ "$(($(seat_now) - start))" -ge "$limit" ]; then
      die "seat: no Unity seat after $UNITY_SEAT_WAIT_MINUTES min (UNITY_SEAT_WAIT_MINUTES); try again later"
    fi
  done
  SEAT_OWNED=1; SEAT_PENDING=0  # before ANY fallible filesystem operation
  if ! mkdir -p "$(dirname "$SEAT_STATE")" || ! marker="$(mktemp "$SEAT_STATE.XXXXXX")"; then
    die "seat: could not persist ownership in $SEAT_STATE"
  fi
  if ! printf '%s %s\n' "$THEROBOTS_TASK_ID" "$$" > "$marker" \
    || ! mv -fT "$marker" "$SEAT_STATE" \
    || [ "$(cat "$SEAT_STATE" 2>/dev/null)" != "$THEROBOTS_TASK_ID $$" ]; then
    rm -f "$marker"
    die "seat: could not persist ownership in $SEAT_STATE"
  fi
  SEAT_PERSISTED=1
  log "seat: acquired a Unity seat"
}

# Give the seat back (after a successful licence return). A failed release only warns: the hub frees it at task end.
seat_release() {
  # An explicit return in another checkout cannot use the original task's token.
  # Ask its live watcher to release that seat, even if a new ULF appears before
  # its next poll. Only fingerprints/paths are persisted, never credentials.
  if [ "${IDLE_RELEASING:-0}" != 1 ] && [ ! -f "$ULF" ]; then idle_retire_owner; fi
  seat_creds && seat_env || return 0
  if [ "${SEAT_OWNED:-0}" != 1 ] && [ "${SEAT_PENDING:-0}" != 1 ]; then seat_held || return 0; fi
  seat_post release
  SEAT_OWNED=0; SEAT_PENDING=0
  if seat_held; then rm -f "$SEAT_STATE"; fi
  case "$SEAT_CODE" in
    2??) log "seat: released the Unity seat" ;;
    *) log "warning: seat release failed (HTTP $SEAT_CODE); the hub frees it when the task ends" ;;
  esac
}

# EXIT trap (bash also runs it on a fatal INT/TERM): a seat THIS invocation acquired whose activation then failed
# (no usable ULF) goes back. A seat with a licence still active stays held between invocations until `return`.
seat_exit() {
  # A successful exit-return may have removed the persisted marker in a subshell.
  if [ "${SEAT_PERSISTED:-0}" = 1 ] && ! seat_held; then return 0; fi
  [ "${SEAT_OWNED:-0}" = 1 ] || [ "${SEAT_PENDING:-0}" = 1 ] || return 0
  if [ -f "$ULF" ] && [ -z "$(ulf_problem)" ]; then return 0; fi
  log "seat: activation failed; releasing the seat this run acquired or queued"
  seat_release
}

# Hold across retirement settlement, activation AND failure cleanup, but not seat polling.
# Return uses the same lock.
# The licence is shared across OUT_DIRs/tasks, unlike their seat markers. Canonicalize
# its path (even before it exists) so aliases share a lock too. Never unlink this
# lock: activation/return can remove the ULF while another invocation is waiting.
# Serialize activators separately from return/retirement, which must progress
# while an activator polls the hub. Always take the gate before the ULF lock.
activation_gate() {
  [ -z "${ACQUISITION_FD:-}" ] || return 0
  local lock; lock="$(readlink -m "$ULF").acquire.lock"
  mkdir -p "$(dirname "$lock")"
  exec {ACQUISITION_FD}> "$lock"
  activation_wait "$ACQUISITION_FD"
}
activation_ungate() {
  [ -n "${ACQUISITION_FD:-}" ] || return 0
  # A licensing worker may still hold an inherited copy of this descriptor.
  flock -u "$ACQUISITION_FD"
  exec {ACQUISITION_FD}>&-
  unset ACQUISITION_FD
}
activation_lock() {
  [ -z "${ACTIVATION_FD:-}" ] || return 0
  local lock; lock="$(readlink -m "$ULF").lock"
  mkdir -p "$(dirname "$lock")"
  exec {ACTIVATION_FD}> "$lock"
  activation_wait "$ACTIVATION_FD"
}
activation_wait() {
  # Bounded attempts let wrapper cancellation run even if the holder is hung.
  local rc
  while :; do
    rc=0
    flock -x -w 1 -E 75 "$1" || rc=$?
    [ "$rc" != 0 ] || break
    [ "$rc" != 75 ] || continue
    die "activation lock failed (flock exit $rc)"
  done
}
activation_unlock() {
  [ -n "${ACTIVATION_FD:-}" ] || return 0
  flock -u "$ACTIVATION_FD"
  exec {ACTIVATION_FD}>&-
  unset ACTIVATION_FD
}
seat_cleanup() {
  if [ "${SEAT_OWNED:-0}" = 1 ] || [ "${SEAT_PENDING:-0}" = 1 ]; then activation_lock; fi
  seat_exit
  activation_unlock
  activation_ungate
}

# Always unlock, including outside a hub task. Seat operations themselves check the env.
arm_seat_exit() {
  chain_exit_trap seat_cleanup
  if seat_env; then seat_on || true; fi
}

# Like activation_lock, all idle coordination belongs to the canonical licence,
# not a checkout. Keep these lock files for the lifetime of the Linux account:
# unlinking them would split waiters across different inodes on reactivation.
IDLE_DIR="$(readlink -m "$ULF").idle"
IDLE_ACTIVITY="$IDLE_DIR/unity-activity"
IDLE_PID="$IDLE_DIR/unity-idle.pid"
IDLE_ACTIVE="$IDLE_DIR/unity-active"
IDLE_CONTEXT="$IDLE_DIR/unity-idle.context"
IDLE_LAUNCH="$IDLE_DIR/unity-idle.launch"
IDLE_OWNER="$IDLE_DIR/unity-idle.owner"
IDLE_SEAT="$IDLE_DIR/unity-idle.seat"
IDLE_ACTIVITY_LOCK="$IDLE_DIR/unity-activity.lock"
IDLE_WATCH_LOCK="$IDLE_DIR/unity-idle.lock"
UNITY_IDLE_RETURN_MINUTES="${UNITY_IDLE_RETURN_MINUTES:-10}"

# Compare credentials and ownership without writing secrets to disk or putting them on argv.
# Include paths/policy too: an old checkout/client or grace period must not silently win.
idle_context() {
  local fingerprint creds=0 hub=0
  seat_creds && creds=1
  seat_env && hub=1
  fingerprint="$(printf '%s\0' "${UNITY_USERNAME:-}" "${UNITY_PASSWORD:-}" \
    "${THEROBOTS_HUB_URL:-}" "${THEROBOTS_TASK_ID:-}" "${THEROBOTS_TASK_TOKEN:-}" \
    "$(readlink -m "$ULF")" "$SEAT_STATE" "$(cat "$SEAT_STATE" 2>/dev/null || true)" \
    "$LC" "$PROJECT" "$IDLE_SCRIPT" \
    "$UNITY_IDLE_RETURN_MINUTES" "${UNITY_RETURN_TIMEOUT:-60}" | sha256sum | cut -d' ' -f1)"
  printf '%s:%s:%s\n' "$fingerprint" "$creds" "$hub"
}

# Called after a successful explicit return, under the activation lock. The
# fingerprint-specific request survives a quick reactivation/context handoff.
idle_retire_owner() {
  local owner state context
  owner="$(cat "$IDLE_OWNER" 2>/dev/null || true)"
  state="$(cat "$IDLE_SEAT" 2>/dev/null || true)"
  context="$(cat "$IDLE_CONTEXT" 2>/dev/null || true)"
  [ -n "$owner" ] && [ -n "$context" ] && [ -f "$state" ] || return 0
  [ "$(cut -d' ' -f1 "$state")" = "$owner" ] || return 0
  if [ "$owner" = "${THEROBOTS_TASK_ID:-}" ] && [ "$state" = "$SEAT_STATE" ]; then return 0; fi
  # Capture the exact acquisition, not just task identity: an old watcher must
  # never release a later seat acquired by the same task in the same checkout.
  (umask 077; printf '%s\n%s\n' "$(cat "$state")" "$state" > "$IDLE_DIR/retire.$context")
}

# Under the activity lock, release only this watcher's explicitly owned seat.
# A replacement may already be published: never release with its environment.
idle_release_retired() {
  local context="${IDLE_WATCH_CONTEXT:-}"
  if [ -n "$context" ] && [ -f "$IDLE_DIR/retire.$context" ]; then
    activation_lock
    # A new activation by the same task may have settled this request while
    # we waited. Never release its freshly acquired seat instead.
    if [ -f "$IDLE_DIR/retire.$context" ]; then
      local acquisition state
      { read -r acquisition; read -r state; } < "$IDLE_DIR/retire.$context"
      if [ "$state" = "$SEAT_STATE" ] && seat_creds && seat_env && seat_held \
        && [ "$(cat "$SEAT_STATE")" = "$acquisition" ]; then IDLE_RELEASING=1 seat_release; fi
      rm -f "$IDLE_DIR/retire.$context"
      activation_unlock
      return 0
    fi
    activation_unlock
  fi
  return 1
}

# Caller holds the activation lock. The same task can settle its old
# checkout's request with its own token before re-acquiring (or reusing) a seat.
idle_settle_own_retirement() {
  local request acquisition state
  for request in "$IDLE_DIR"/retire.*; do
    [ -f "$request" ] || continue
    { read -r acquisition; read -r state; } < "$request"
    [ -f "$state" ] && [ "$(cut -d' ' -f1 "$state")" = "${THEROBOTS_TASK_ID:-}" ] || continue
    if [ "$(cat "$state")" = "$acquisition" ]; then
      SEAT_STATE="$state" IDLE_RELEASING=1 seat_release
    fi
    rm -f "$request"
  done
}

# shellcheck source=Tools/ship/lib/linux-unity-idle.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-idle.sh"

idle_begin() {
  IDLE_SCRIPT="$(readlink -f "${BASH_SOURCE[1]}")"
  (umask 077; mkdir -p "$IDLE_ACTIVE")
  (
    flock -x 9
    touch "$IDLE_ACTIVITY"
    # Full run identity prevents PID recycling from displacing an orphan's marker.
    proc_start "$$" > "$IDLE_ACTIVE/$$:$(proc_start "$$")"
  ) 9> "$IDLE_ACTIVITY_LOCK"
}

# Under the activity lock: the advertisement or a detached launcher must still
# name this context and a live process. Context alone is not a liveness claim.
idle_context_live() {
  local f pid start context
  for f in "$IDLE_PID" "$IDLE_LAUNCH"; do
    [ -f "$f" ] || continue
    read -r pid start context < "$f" || continue
    # Two-field pidfiles from older clients belong to the published context.
    [ "$f" != "$IDLE_PID" ] || context="${context:-$1}"
    if [ "$context" = "$1" ] && same_proc "$pid:$start"; then return 0; fi
  done
  return 1
}

idle_finish() {
  (
    flock -x 9
    touch "$IDLE_ACTIVITY"
    rm -f "$IDLE_ACTIVE/$$:$(proc_start "$$")"
    [ -f "$ULF" ] && [ -z "$(ulf_problem)" ] || exit 0
    local pid start context old_context owner state
    context="$(idle_context)"
    old_context="$(cat "$IDLE_CONTEXT" 2>/dev/null || true)"
    if idle_context_live "$old_context"; then
      # A live pre-upgrade shared watcher has no owner metadata. Do not replace
      # its original task's release environment with a foreign invocation.
      if [ -n "$old_context" ] && [ ! -f "$IDLE_OWNER" ]; then exit 0; fi
      # Utility commands may omit release credentials/ownership. Preserve only a
      # live watcher or in-flight replacement, never a stale capability claim.
      if [[ "$old_context" = *:1:? ]] && ! seat_creds; then exit 0; fi
      if [[ "$old_context" = *:1 ]] && ! seat_env; then exit 0; fi
      state="$(cat "$IDLE_SEAT" 2>/dev/null || true)"
      owner="$(cut -d' ' -f1 "$state" 2>/dev/null || true)"
      # B has a different checkout-local SEAT_STATE. Consult A's advertised path,
      # not B's empty marker, before replacing the only environment able to
      # release A. A retirement request permits handoff after explicit return.
      if [ -n "$owner" ] && [ "$(cat "$IDLE_OWNER" 2>/dev/null || true)" = "$owner" ] \
        && { [ "$owner" != "${THEROBOTS_TASK_ID:-}" ] || [ "$state" != "$SEAT_STATE" ]; } \
        && [[ "$old_context" = *:1:1 ]] && [ ! -f "$IDLE_DIR/retire.$old_context" ]; then exit 0; fi
      [ "$old_context" != "$context" ] || exit 0
    fi
    # Publication and the watcher's final context check share the activity lock.
    (umask 077
      printf '%s\n' "$context" > "$IDLE_CONTEXT"
      printf '%s\n' "${THEROBOTS_TASK_ID:-}" > "$IDLE_OWNER"
      printf '%s\n' "$SEAT_STATE" > "$IDLE_SEAT")
    # An obsolete watcher retires at its next poll. Detached replacements re-check context while waiting.
    # Export fallback credentials too; never put secrets on argv. Inherit neither the activity lock nor run marker.
    mkdir -p "$OUT_DIR"
    (exec 9>&-; unset LINUX_UNITY_RUN
      export UNITY_USERNAME UNITY_PASSWORD PROJECT OUT_DIR ULF PIDFILE SEAT_STATE
      IDLE_WATCH_CONTEXT="$context" nohup bash "$IDLE_SCRIPT" __idle-return </dev/null >> "$OUT_DIR/unity-idle.log" 2>&1 &
      pid=$!; start="$(proc_start "$pid" || true)"
      (umask 077; printf '%s %s %s\n' "$pid" "$start" "$context" > "$IDLE_LAUNCH"))
  ) 9> "$IDLE_ACTIVITY_LOCK"
}

idle_watch() {
  local grace now last rc delay=5
  [[ "$UNITY_IDLE_RETURN_MINUTES" =~ ^[0-9]+$ ]] || die "UNITY_IDLE_RETURN_MINUTES must be whole minutes"
  grace=$((10#$UNITY_IDLE_RETURN_MINUTES * 60))
  (umask 077; mkdir -p "$IDLE_DIR")
  mkdir -p "$OUT_DIR"
  # An old launcher may reach us after its successor already owns the watcher
  # lock. Honour its seat retirement before waiting or rejecting its context.
  (flock -x 9; idle_release_retired) 9> "$IDLE_ACTIVITY_LOCK" && return 0
  exec 8> "$IDLE_WATCH_LOCK"
  if [ -n "${IDLE_WATCH_CONTEXT:-}" ]; then
    # Only background replacements wait here; CLI commands never wait on the watcher lock.
    until flock -w 5 8; do
      [ "$(cat "$IDLE_CONTEXT" 2>/dev/null || true)" = "$IDLE_WATCH_CONTEXT" ] || return 0
    done
  else flock -n 8 || return 0; fi
  (
    flock -x 9
    [ -z "${IDLE_WATCH_CONTEXT:-}" ] \
      || [ "$(cat "$IDLE_CONTEXT" 2>/dev/null || true)" = "$IDLE_WATCH_CONTEXT" ] || exit 1
    printf '%s %s %s\n' "$$" "$(proc_start "$$")" "${IDLE_WATCH_CONTEXT:-}" > "$IDLE_PID"
    [ "$(cut -d' ' -f1 "$IDLE_LAUNCH" 2>/dev/null)" != "$$" ] || rm -f "$IDLE_LAUNCH"
  ) 9> "$IDLE_ACTIVITY_LOCK" || return 0
  trap '[ "$(cut -d" " -f1 "$IDLE_PID" 2>/dev/null)" != "$$" ] || rm -f "$IDLE_PID"' EXIT
  while :; do
    if [ -f "$ULF" ]; then sleep "$delay"; fi
    rc=0
    (
      flock -x 9
      # Fatal poll exits also retire the ad before releasing the activity lock.
      trap 'case "$?" in 2|3) ;; *) idle_unadvertise ;; esac' EXIT
      if idle_release_retired; then idle_unadvertise; exit 0; fi
      # Reject obsolete capabilities before any release, including no-ULF cleanup.
      if [ -n "${IDLE_WATCH_CONTEXT:-}" ] \
        && [ "$(cat "$IDLE_CONTEXT" 2>/dev/null || true)" != "$IDLE_WATCH_CONTEXT" ]; then idle_unadvertise; exit 0; fi
      if [ ! -f "$ULF" ]; then
        activation_lock
        # Recheck after locking: another checkout may have just activated.
        if [ ! -f "$ULF" ]; then
          if seat_creds && seat_env && seat_held; then IDLE_RELEASING=1 seat_release; fi
          idle_unadvertise
          exit 0
        fi
        activation_unlock
      fi
      if idle_busy; then touch "$IDLE_ACTIVITY"; exit 3; fi
      now="$(date +%s)"; last="$(stat -c %Y "$IDLE_ACTIVITY")"
      [ "$((now - last))" -ge "$grace" ] || exit 3
      log "idle: returning licence after $UNITY_IDLE_RETURN_MINUTES min without activity"
      if (cmd_return); then
        # Retire before unlocking: a new activation must not reuse this exiting
        # watcher. Its PID-checked EXIT cleanup cannot erase a successor's ad.
        idle_unadvertise
        # No live activity remains; bound retained orphan records to this licence.
        rm -f "$IDLE_ACTIVE"/*
        exit 0
      fi
      log "warning: idle return failed; will retry (or run $SHIP_COMMAND return)" || :
      exit 2
    ) 9> "$IDLE_ACTIVITY_LOCK" || rc=$?
    [ "$rc" != 0 ] || break
    # Only explicit not-idle (3) and return-failed (2) outcomes are retryable.
    # Fatal errors (including activation_lock's die) must stop the watcher.
    case "$rc" in 2|3) ;; *) return "$rc" ;; esac
    # Sleep outside the activity lock, retrying transient failures without another CLI command.
    # Each attempt is a fresh subshell (RETURN_ATTEMPTED and activation lock cannot leak across retries).
    if [ "$rc" = 2 ]; then
      delay=$((delay * 2)); [ "$delay" -le 60 ] || delay=60
    else delay=5; fi
  done
}
