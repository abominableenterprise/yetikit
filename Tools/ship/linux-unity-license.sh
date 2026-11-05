# shellcheck shell=bash
# Credentials, ULF lifecycle and opt-in exit return. Sourced by linux-unity.sh; needs its log, die, paths
# and seat helpers. Function definitions only: sourcing must not activate, return or arm command traps.

# Strip the account email/password from anything the licensing client prints.
mask() {
  U="${UNITY_USERNAME:-}" P="${UNITY_PASSWORD:-}" perl -pe '
    s/\Q$ENV{U}\E/<email>/gi if length $ENV{U};
    s/\Q$ENV{P}\E/<password>/g if length $ENV{P};
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g;'
}

# The hub passes the Unity login as USERNAME/PASSWORD: use them when UNITY_USERNAME/UNITY_PASSWORD are not both set.
# Runs before need_creds and mask, so both see (and mask) the values in use.
creds_fallback() {
  if [ -n "${UNITY_USERNAME:-}" ] && [ -n "${UNITY_PASSWORD:-}" ]; then return 0; fi
  if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then UNITY_USERNAME="$USERNAME" UNITY_PASSWORD="$PASSWORD"; fi
}

need_creds() {
  [ -n "${UNITY_USERNAME:-}" ] && [ -n "${UNITY_PASSWORD:-}" ] \
    || die "set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)"
}

# Why $ULF (the file at $1, default $ULF) is not a usable licence, or nothing when it looks fine: a ULF is signed XML
# (<License ...> + a closed <Signature>...</Signature>, ending with its root element's closing tag); a non-empty
# <StopDate Value="..."/> in the past means it expired. A revoked licence cannot be seen locally; the editor then
# fails on open, and `return` + `activate` recovers.
ulf_problem() {
  local f="${1:-$ULF}" stop now
  [ -s "$f" ] || { echo "empty"; return; }
  grep -q '<License' "$f" && grep -q '<Signature' "$f" || { echo "not a signed ULF (corrupt or truncated)"; return; }
  # A file cut off inside <Signature still has both opening tags: also require the closing ones.
  perl -0777 -ne 'exit !(m{<Signature\b.*</Signature>}s
    && m{\A(?:\xEF\xBB\xBF)?\s*(?:<\?.*?\?>\s*)?(?:<!--.*?-->\s*)*<([A-Za-z_][\w.:-]*).*</\1>\s*\z}s)' "$f" \
    || { echo "truncated (no closing </Signature> or root element)"; return; }
  stop="$(grep -o '<StopDate Value="[^"]*"' "$f" | head -n1 | sed 's/.*Value="\([^"]*\)"/\1/')" || true
  now="$(date -u +%Y-%m-%dT%H:%M:%S)"
  if [ -n "$stop" ] && [[ "$stop" < "$now" ]]; then echo "expired (StopDate $stop)"; fi
}

# Move an invalid ULF out of the way (kept for inspection) so the next activation starts clean.
set_aside_ulf() {
  local bad; bad="$ULF.invalid-$(date -u +%Y%m%dT%H%M%S)"
  # Keep a configured symlink in place so all commands retain the same lock identity.
  mv -f "$(readlink -m "$ULF")" "$bad"
  log "moved the invalid licence to $bad"
}

# Call only in a child shell: keep wrapper-owned locks out of client workers.
licensing_close_locks() {
  [ -z "${ACQUISITION_FD:-}" ] || exec {ACQUISITION_FD}>&-
  [ -z "${ACTIVATION_FD:-}" ] || exec {ACTIVATION_FD}>&-
  [ -z "${UNITY_CLEANUP_FD:-}" ] || exec {UNITY_CLEANUP_FD}>&-
}

# A wrapper-only signal must not leave a client activating after seat cleanup.
activation_signal() {
  local status="$2" i
  trap '' TERM INT HUP
  # Async jobs inherit SIGINT ignored with job control off. Translate every
  # cancellation to TERM, then bound even a client that ignores TERM. Bash
  # reaps completed async jobs between commands; wait collects its status.
  # A signal can arrive before setsid has established the group. Fall back to
  # its still-unexec'd PID, and keep checking both identities during startup.
  kill -TERM -- "-$client" 2>/dev/null || kill -TERM "$client" 2>/dev/null || true
  for ((i=0; i<100; i++)); do
    { kill -0 -- "-$client" 2>/dev/null || kill -0 "$client" 2>/dev/null; } || break
    /bin/sleep 0.02
  done
  # The parent may have exited while a forked worker still holds the group.
  kill -KILL -- "-$client" 2>/dev/null || true
  kill -KILL "$client" 2>/dev/null || true
  wait "$client" 2>/dev/null || true
  mask < "$capture" >&2
  rm -f "$capture"
  exit "$status"
}
activate_client() {
  local capture client rc=0 saved sig
  capture="$(mktemp)"
  saved="$(trap -p TERM INT HUP)"
  # Isolate the full client tree; $! is the session/group leader (job control is off).
  # Even if the client exits on TERM, its workers remain addressable for escalation.
  (licensing_close_locks; exec setsid "$LC" --activate-ulf --username "$UNITY_USERNAME" --password "$UNITY_PASSWORD") > "$capture" 2>&1 &
  client=$!
  trap 'activation_signal TERM 143' TERM
  trap 'activation_signal INT 130' INT
  trap 'activation_signal HUP 129' HUP
  wait "$client" || rc=$?
  # Restore live wrapper handlers directly, never through a default-disposition window.
  eval "$saved"
  for sig in TERM INT HUP; do
    [[ "$saved" = *" SIG$sig"* ]] || trap - "$sig"
  done
  mask < "$capture" >&2
  rm -f "$capture"
  return "$rc"
}

# Activation runs in the command shell, including APK builds, so cleanup chains
# remain owned by the wrapper until its full lifecycle has finished.
cmd_activate() {
  chain_exit_trap seat_cleanup
  need_creds
  local why seat_ready=0
  activation_gate
  while :; do
    activation_lock
    [ -x "$LC" ] || die "licensing client not found; run \`$SHIP_COMMAND setup\` first"
    if [ -f "$ULF" ]; then
      why="$(ulf_problem)"
      if [ -z "$why" ]; then
        log "ULF licence already present at $ULF (checked)"
        activation_unlock; activation_ungate; return
      fi
      log "existing ULF licence at $ULF is invalid: $why; re-activating"
      set_aside_ulf
    fi
    # A previous same-task watcher may have released our seat in the unlocked
    # gap after seat_acquire. Revalidate under this lock before licensing.
    if [ "$seat_ready" = 1 ] && { [ "${SEAT_REQUIRED:-0}" = 0 ] || seat_held; }; then break; fi
    # A retired watcher needs this lock to free the seat we are waiting for.
    activation_unlock
    seat_acquire
    seat_ready=1
    # Another checkout may have activated while we waited; recheck under lock.
  done
  log "activating Unity Personal (ULF)"
  activate_client || exit "$?"
  [ -f "$ULF" ] || die "activation left no $ULF (recover: $SHIP_COMMAND return, then activate)"
  why="$(ulf_problem)"
  [ -z "$why" ] || die "activation wrote an invalid $ULF ($why); recover: $SHIP_COMMAND return, rm $ULF, then activate"
  (licensing_close_locks; exec "$LC" --showEntitlements) 2>&1 | mask | grep -E 'Product Name|com.unity.editor.headless' >&2 || true
  SEAT_OWNED=0; SEAT_PERSISTED=0
  activation_unlock
  activation_ungate
}

cmd_return() {
  [ "${RETURN_ATTEMPTED:-0}" = 0 ] || return 0
  RETURN_ATTEMPTED=1
  activation_lock
  if [ ! -f "$ULF" ]; then
    log "return: licence already returned"; seat_release; return 0
  fi
  need_creds
  [ -x "$LC" ] || die "licensing client not found"
  log "returning ULF licence"
  local out capture rc=0 limit="${UNITY_RETURN_TIMEOUT:-60}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "UNITY_RETURN_TIMEOUT must be positive whole seconds"
  # Keep the supervised shell alive after TERM even if the client exits: timeout must still KILL its group.
  # Capture to a file so an inherited output pipe cannot keep this command (and the activity lock) blocked.
  capture="$(mktemp)"
  (licensing_close_locks; exec timeout -k 5 "$limit" bash -c '
    trap "while :; do /bin/sleep 1; done" TERM
    "$@" & wait $!
  ' _ "$LC" --return-ulf --username "$UNITY_USERNAME" --password "$UNITY_PASSWORD") > "$capture" 2>&1 || rc=$?
  out="$(< "$capture")"; rm -f "$capture"
  printf '%s\n' "$out" | mask >&2
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then log "return: licensing client timed out after $limit s (UNITY_RETURN_TIMEOUT)"; fi
  # Nothing to give back (already returned, or never activated on this VM): that is fine.
  if grep -qi 'Ulf license file not found' <<< "$out"; then
    log "return: licence already returned"; rc=0
  fi
  if [ "$rc" = 0 ]; then rm -f "$(readlink -m "$ULF")"; seat_release; fi
  return $rc
}

# Every editor run needs the ULF. If it vanished (returned, wiped), re-activate once when credentials are set.
# An invalid one (see ulf_problem) counts as missing.
ensure_licence() {
  local why="missing"
  if [ -f "$ULF" ]; then why="$(ulf_problem)"; [ -n "$why" ] || return 0; fi
  if [ -n "${UNITY_USERNAME:-}" ] && [ -n "${UNITY_PASSWORD:-}" ]; then
    log "ULF licence at $ULF is $why; re-activating once"
    cmd_activate
  else
    die "ULF licence at $ULF is $why; set UNITY_USERNAME/UNITY_PASSWORD and run activate"
  fi
}

# Guard each handler against errexit, report its status, and leave EXIT_RC alone. Handlers must explicitly
# propagate internal failures: Bash disables errexit inside a function invoked in an || list.
run_exit_cleanup() {
  local handler="$1" rc=0
  eval "$handler" || rc=$?
  if [ "$rc" != 0 ]; then
    printf '[linux-unity] warning: exit cleanup failed (exit %s): %s\n' "$rc" "$handler" >&2 || :
  fi
  return 0
}

# Run $1 first on exit, then the EXIT trap already set (cmd_setup's install_editor saves and restores it the same
# way). EXIT_RC preserves the command failure; return_on_exit may fail an otherwise successful command.
chain_exit_trap() {
  local old=() handler
  eval "old=($(trap -p EXIT))"   # trap -- '<command>' EXIT
  printf -v handler '%q' "$1"
  unset EXIT_RC
  # shellcheck disable=SC2064 # expand the previous command and quoted handler now
  trap "EXIT_RC=\${EXIT_RC:-\$?}; run_exit_cleanup $handler; ${old[2]:-:}; exit \"\$EXIT_RC\"" EXIT
}

# One return path for all commands, including explicit return; preserve an earlier command failure.
return_on_exit() {
  local ret=0
  [ "${RETURN_ATTEMPTED:-0}" = 0 ] || return 0
  log "UNITY_RETURN_ON_EXIT=1: returning the held licence" || :
  (cmd_return) || ret=$?
  [ "$ret" = 0 ] && return 0
  log "error: licence return failed (exit $ret); the activation may still be in use: run ${SHIP_COMMAND:-linux-unity.sh} return" || :
  [ "$EXIT_RC" != 0 ] || EXIT_RC=$ret
}

arm_return_on_exit() {
  [ "${UNITY_RETURN_ON_EXIT:-0}" = 1 ] || return 0
  chain_exit_trap return_on_exit
}
