#!/usr/bin/env bash
# Shared invocation supervisor for GNU timeout and the stock macOS fallback.
# Keep the supervisor in the caller's group for release-step cancellation, but
# put only the timed command in a new group so a timeout cannot hit siblings.

# shellcheck source=Tools/ship/quest-release/workers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workers.sh"

# Zombies cannot hold resources; orphaned grandchildren are reaped by the OS.
qr_group_alive() {
  ps -axo pgid=,stat= | awk -v group="$1" '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }'
}

# Always launched asynchronously by the supervisor; use that shell directly
# so $! tracks the shell that traps TERM and waits for its sleep.
qr_timebox_watchdog() {
  # Do not leave the timer's sleep behind, including on cancellation during fork.
  trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM
  sleep "$1" &
  wait
  kill -ALRM "$2" 2>/dev/null || true
} >/dev/null 2>&1

# Wait for the whole group, not merely the wrapper that originally led it.
qr_timebox_drain() {
  local ticks cancel_ticks=5 orphan_ticks=20
  qr_group_alive "$group" || return 0
  kill -TERM -- "-$group" 2>/dev/null || true
  kill -CONT -- "-$group" 2>/dev/null || true
  ticks="$(awk -v grace="$grace" 'BEGIN {printf "%d", grace * 10 + 0.99}')"
  while qr_group_alive "$group"; do
    # Outer release cancellation can escalate in about a second. Do not
    # leave it to kill this supervisor before the isolated group is drained.
    # If the wrapper is gone, give surviving children at most two seconds.
    # The longer editor grace is for the command itself to shut down cleanly.
    if [ "$cancel_ticks" -le 0 ] || [ "$orphan_ticks" -le 0 ] || [ "$ticks" -le 0 ]; then
      kill -KILL -- "-$group" 2>/dev/null || true
    else
      ticks=$((ticks - 1))
      [ "$cancelled" != 1 ] || cancel_ticks=$((cancel_ticks - 1))
      kill -0 "$group" 2>/dev/null || orphan_ticks=$((orphan_ticks - 1))
    fi
    command sleep 0.1
  done
}

qr_timebox_supervise() {
  local secs="$1" grace="$2" group timer='' supervisor slot rc=0 timed_out=0 cancelled=0
  shift 2
  # Latch signals during launch and registration. In particular, a release
  # cancel must not lose the new group between fork and the $! assignment.
  trap 'timed_out=1' ALRM
  trap 'cancelled=1' HUP INT TERM
  slot="$(qr_worker_slot "${QR_TIMEBOX_WORKERS:-}")" || exit 1
  if [ -n "$slot" ] || [ -n "$secs" ]; then
    # $$ is the release owner in subshells (and Bash 3.2 has no BASHPID).
    supervisor="$(exec sh -c 'printf "%s\n" "$PPID"')" || exit 1
  else supervisor=""; fi
  set -m
  (
    set +m
    qr_worker_await "$slot" "$supervisor" || exit 1
    case "$(type -t -- "$1")" in
      function|builtin) "$@" ;;
      *) exec "$@" ;;
    esac
  ) <&0 &
  group=$!
  set +m
  if [ "$timed_out$cancelled" = 00 ] && ! qr_worker_publish "$slot" "$group"; then
    rc=1; qr_timebox_finish
  fi
  if [ -n "$secs" ]; then
    qr_timebox_watchdog "$secs" "$supervisor" &
    timer=$!
  fi
  # Drain from the trap too: a signal immediately before wait must not
  # leave us waiting indefinitely on a TERM-resistant command.
  trap 'timed_out=1; qr_timebox_finish' ALRM
  trap 'cancelled=1; qr_timebox_finish' HUP INT TERM
  if [ "$timed_out$cancelled" = 00 ]; then wait "$group" || rc=$?; fi
  qr_timebox_finish
}

# The supervisor always runs in its own shell.
qr_timebox_finish() {
  # Additional signals only update the outcome while cleanup is running.
  trap 'timed_out=1' ALRM
  trap 'cancelled=1' HUP INT TERM
  qr_timebox_drain
  if [ -n "$timer" ]; then
    kill -TERM "$timer" 2>/dev/null || true
    wait "$timer" 2>/dev/null || true
    timer=''
  fi
  if [ -n "$slot" ]; then qr_worker_drain_group "$group"; fi
  wait "$group" 2>/dev/null || true
  if [ -n "$slot" ]; then
    qr_workers_drain "$slot/group.$group" && rm -rf "$slot" || rc=1
  fi
  if [ "$timed_out" = 1 ]; then exit 124; fi
  if [ "$cancelled" = 1 ]; then exit 143; fi
  exit "$rc"
}

qr_timebox() {
  local secs="$1" rc=0 grace="${QR_TIMEBOX_KILL_AFTER:-60}"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    # GNU timeout signals the supervisor, which owns TERM/CONT/KILL and reaping.
    # ALRM distinguishes the deadline from a release cancellation via TERM.
    QR_TIMEBOX_WORKERS="${QR_TIMEBOX_WORKERS:-}" \
      gtimeout --foreground -s ALRM "$secs" bash "$QR_SHIP_DIR/quest-release/timebox.sh" '' "$grace" "$@" || rc=$?
  else
    ( qr_timebox_supervise "$secs" "$grace" "$@" ) || rc=$?
  fi
  [ "$rc" != 124 ] || qr_log "timed out after ${secs}s: ${1##*/}"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  qr_timebox_supervise "$@"
fi
