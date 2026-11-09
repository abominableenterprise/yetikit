# shellcheck shell=bash
# quest-release `wait [minutes]`: block until the current run (release-logs/current.env + run.lock) is finished, so a host
# task makes one tool call instead of `sleep 85` polls. Finished: the lock is gone or its PID is dead (kill -0, never a
# process search) AND the run folder has a summary.txt written after the run started. Then prints summary.txt and exits 0
# when the install says ok (or a gate-only run's gate passed), 1 otherwise; 124 on timeout with the logs' last lines.
# Read-only: takes no lock, writes nothing (no qr_log to release.log, no qr_set). Sourced by Tools/ship/quest-release.sh;
# bash 3.2 compatible.

qr_wait_now() { date +%s; }
qr_wait_say() { printf '[quest-release] wait: %s\n' "$*" >&2; }

# mtime of $1 in (fractional) epoch seconds; empty when missing. perl ships with macOS; stat's flags differ by OS.
qr_wait_mtime() { [ -e "$1" ] && perl -MTime::HiRes=stat -e 'print +(stat $ARGV[0])[9], "\n"' "$1"; }

# Unpinned fallback only: the lock's folder, else current.env's. A pinned pending lock must not use prior state.
qr_wait_run_dir() {
  local f
  if [ -d "${QR_LOCK_RUN:-}" ]; then printf '%s\n' "$QR_LOCK_RUN"; return 0; fi
  f="$(qr_state_file)"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  ( . "$f"; printf '%s\n' "${QR_RUN_DIR:-}" )
}

# What the run is doing, from its summary keys (each step's qr_set).
qr_wait_phase() {
  local s="$1/summary" g=running b=running
  if [ -z "$1" ] || [ ! -f "$s/commit" ]; then echo prepare; return 0; fi
  if [ -f "$s/launch" ]; then echo cleanup
  elif grep -q '^install ok' "$s/install" 2>/dev/null; then echo launch
  elif grep -q '^install ' "$s/install" 2>/dev/null || [ -f "$s/cert" ]; then echo install
  elif [ -f "$s/gate" ] && [ -f "$s/apk" ]; then echo verify
  else
    [ -f "$s/gate" ] && g="done"
    [ -f "$s/apk" ] && b="done"
    echo "gate/build (gate $g, build $b)"
  fi
}

# The invocation already exited 0. Check only summary outcomes owned by its command, not stale fields from earlier
# commands sharing this run folder. all also needs an intact install and no launch crash.
qr_wait_verdict() {
  local s="$1/summary" cmd="$2" install label=install
  if [ "$(cat "$s/multi_command" 2>/dev/null)" = "$cmd" ]; then
    [ "$(cat "$s/multi_result" 2>/dev/null)" = 0 ]; return $?
  fi
  case "$cmd" in
    gate) [ "$(cat "$s/gate_result" 2>/dev/null)" = passed ]; return $? ;;
    prepare|build|verify|cleanup) return 0 ;;
    launch) ! grep -qE '^(CRASH|INFRA):' "$s/launch" 2>/dev/null; return $? ;;
    rollback) label=rollback ;;
    all|install) ;;
    *) return 1 ;;
  esac
  install="$(cat "$s/install" 2>/dev/null)"
  case "$install" in
    "$label ok ("*CHANGED*) return 1 ;;
    "$label ok ("*)
      [ "$cmd" != all ] || ! grep -qE '^(CRASH|INFRA):' "$s/launch" 2>/dev/null
      return $? ;;
    *) return 1 ;;
  esac
}

qr_wait_tails() {
  local f shown=0
  for f in gate.out build.out; do
    [ -f "$1/$f" ] || continue
    echo "--- last 5 lines of $1/$f"; tail -n 5 "$1/$f"; shown=1
  done
  [ "$shown" = 1 ] && return 0
  for f in "$1"/release.log "$1"/*-unity.log; do
    [ -f "$f" ] || continue
    echo "--- last 5 lines of $f"; tail -n 5 "$f"
  done
}

# Snapshot the atomic last-result once: PID (when observed), freshness and run folder must identify the watched
# invocation. A pre-prepare failure may have no run folder, but cannot certify an older summary as successful.
# $1 PID, $2 start time, $3 run folder (empty if unresolved). Only a pinned PID with a known start time may
# resolve an unknown folder from this record. Prints the folder, then "rc cmd"; returns 1 if there is no match.
qr_wait_result() {
  local f="$QR_LOGS/last-result" record p rc cmd run
  [ -f "$f" ] || return 1
  record="$(cat "$f")"
  p="$(printf '%s\n' "$record" | sed -n 's/^pid=//p')"
  rc="$(printf '%s\n' "$record" | sed -n 's/^rc=//p')"
  cmd="$(printf '%s\n' "$record" | sed -n 's/^cmd=//p')"
  run="$(printf '%s\n' "$record" | sed -n 's/^run=//p')"
  [ -z "$1" ] || [ "$p" = "$1" ] || return 1
  perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$(qr_wait_mtime "$f")" "${2:-0}" || return 1
  [ "$run" = "$3" ] \
    || { [ -z "$3" ] && [ -n "$1" ] && [ -n "$2" ]; } \
    || { [ -z "$run" ] && [ "$rc" != 0 ]; } || return 1
  printf '%s\n%s %s\n' "$run" "$rc" "$cmd"
}

qr_wait() {
  local minutes="${1:-45}" poll="${QUEST_WAIT_POLL:-5}" grace="${QUEST_WAIT_GRACE:-15}" t0 now deadline
  local last_line seen=0 start="" run="" st wpid="" res
  case "$minutes" in ''|*[!0-9]*) qr_wait_say "usage: wait [minutes]"; return 2 ;; esac
  minutes=$((10#$minutes))
  t0="$(qr_wait_now)"; deadline=$((t0 + minutes * 60)); last_line="$t0"
  while :; do
    st=0; qr_lock_read || st=$?
    # Pin the first numeric owner, including a stale lock. A later owner means this invocation ended, not a new
    # invocation to follow. Keep its start and run folder too (prepare may fill in the folder while it holds the lock).
    if [ -z "$wpid" ]; then
      case "$QR_LOCK_PID" in
        ''|*[!0-9]*)
          # A short-lived invocation can finish before our first poll, without ever preparing a run folder.
          # Its published identity, not historical current.env, selects the required terminal result.
          if [ $(( $(qr_wait_now) - t0 )) -ge "$grace" ] && [ -f "$QR_LOGS/current-invocation" ]; then
            wpid="$(cat "$QR_LOGS/current-invocation")"
            case "$wpid" in ''|*[!0-9]*) qr_wait_say "invalid invocation identity"; return 1 ;; esac
            seen=1; run=""; start="$(qr_wait_mtime "$QR_LOGS/current-invocation")"
          fi ;;
        *) wpid="$QR_LOCK_PID"; seen=1; run=""
           start="$(qr_wait_mtime "$(qr_lock_dir)/pid")"
           [ -n "$start" ] || start="$(qr_wait_mtime "$(qr_lock_dir)")" ;;
      esac
    fi
    # Never cache current.env for a pinned pending prepare: it may describe the previous run. Once concrete,
    # keep the folder even if the lock disappears; only this PID's lock or validated result may resolve it.
    if [ -z "$wpid" ]; then
      run="$(qr_wait_run_dir)"
    elif [ "$QR_LOCK_PID" = "$wpid" ] && [ -z "$run" ] && [ -d "${QR_LOCK_RUN:-}" ]; then
      run="$QR_LOCK_RUN"
    fi
    [ -z "$wpid" ] || [ "$QR_LOCK_PID" = "$wpid" ] || st=1
    now="$(qr_wait_now)"
    if [ "$st" != 0 ]; then
      # No lock at all: the run is over, or (just after a nohup start) not locked yet; after a short grace the run's
      # start is when prepare wrote current.env.
      if [ "$seen" = 0 ] && [ $((now - t0)) -ge "$grace" ]; then
        [ -n "$run" ] || { qr_wait_say "no quest-release run in $QR_LOGS"; return 1; }
        start="$(qr_wait_mtime "$(qr_state_file)")"; seen=1
      fi
      if [ "$seen" = 1 ]; then
        # Without an observed lock, current.env supplies the earliest valid result time and the run identity.
        if res="$(qr_wait_result "$wpid" "$start" "$run")"; then
          [ -n "$run" ] || run="${res%%$'\n'*}"
          res="${res#*$'\n'}"
          [ -f "$run/summary.txt" ] && cat "$run/summary.txt"
          qr_wait_say "the run (${res#* }, pid ${wpid:-of the last run}) exited ${res%% *}"
          [ "${res%% *}" = 0 ] && [ -f "$run/summary.txt" ] \
            && perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$(qr_wait_mtime "$run/summary.txt")" "${start:-0}" \
            && qr_wait_verdict "$run" "${res#* }"
          return
        fi
        qr_wait_say "the run ${wpid:+(pid $wpid) }ended (lock gone) without writing its result (killed?)"
        [ -z "$run" ] || qr_wait_tails "$run"
        return 1
      fi
    fi
    if [ "$now" -ge "$deadline" ]; then
      qr_wait_say "timed out after $minutes min; the run (pid ${QR_LOCK_PID:-?}) is still going, phase $(qr_wait_phase "$run")"
      [ -z "$run" ] || qr_wait_tails "$run"
      return 124
    fi
    if [ $((now - last_line)) -ge 60 ]; then
      last_line="$now"
      qr_wait_say "$(( (now - t0) / 60 )) min: phase $(qr_wait_phase "$run") (pid ${QR_LOCK_PID:-?}, ${run:-no run folder yet})"
    fi
    sleep "$poll"
  done
}
