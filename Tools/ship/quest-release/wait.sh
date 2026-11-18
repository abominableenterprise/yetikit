# shellcheck shell=bash
# quest-release `wait [minutes]`: watch the current lock generation, then print its frozen report and return
# 0 for success, 1 for failure or missing result, 124 on timeout with the logs' last lines.
# Read-only: takes no lock and writes nothing. Sourced by Tools/ship/quest-release.sh; Bash 3.2 compatible.

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
    perf) [ "$(cat "$s/perf_result" 2>/dev/null)" = 0 ]; return $? ;;
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

# A keyed waiter reads only its invocation's record, never a successor's last-result.
# Legacy locks have only a PID and use the old freshness and run-folder checks.
# $1 PID, $2 start time, $3 run folder, $4 invocation key. Emits folder, rc, command,
# frozen verdict (blank for a legacy mutable summary), then the optional report.
qr_wait_result() {
  local f="$QR_LOGS/last-result" record header p rc cmd run verdict marker=$'\nreport:'
  if [ -n "$4" ]; then
    [[ "$4" =~ ^run\.[a-zA-Z0-9]{10}$ ]] || return 1
    f="$QR_LOGS/invocations/$4/result"
  fi
  record="$(cat "$f" 2>/dev/null)" || return 1
  if [[ "$record" != *"$marker"* ]]; then marker=$'\nlist-summary:'; fi
  header="${record%%"$marker"*}"
  p="$(printf '%s\n' "$header" | sed -n 's/^pid=//p')"
  rc="$(printf '%s\n' "$header" | sed -n 's/^rc=//p')"
  cmd="$(printf '%s\n' "$header" | sed -n 's/^cmd=//p')"
  run="$(printf '%s\n' "$header" | sed -n 's/^run=//p')"
  verdict="$(printf '%s\n' "$header" | sed -n 's/^verdict=//p')"
  [ -z "$1" ] || [ "$p" = "$1" ] || return 1
  [ -n "$4" ] || perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$(qr_wait_mtime "$f")" "${2:-0}" || return 1
  [ "$run" = "$3" ] \
    || { [ -z "$3" ] && { [ -n "$4" ] || { [ -n "$1" ] && [ -n "$2" ]; }; }; } \
    || { [ -z "$run" ] && [ "$rc" != 0 ]; } || return 1
  if [ "$header" != "$record" ] && [ -z "$verdict" ]; then verdict="$rc"; fi # old list report
  [ -z "$4" ] || [ "$verdict" = 0 ] || [ "$verdict" = 1 ] || return 1
  printf '%s\n%s %s %s\n' "$run" "$rc" "$cmd" "$verdict"
  if [ "$header" != "$record" ]; then printf '%s' "${record#*"$marker"}"; fi
}

qr_wait() {
  local minutes="${1:-45}" poll="${QUEST_WAIT_POLL:-5}" grace="${QUEST_WAIT_GRACE:-15}" t0 now deadline
  local last_line seen=0 start="" run="" st wpid="" key="" res terminal rc cmd verdict
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
          if [ "$st" != 0 ] && [ $(( $(qr_wait_now) - t0 )) -ge "$grace" ] && [ -f "$QR_LOGS/current-invocation" ]; then
            read -r wpid key < "$QR_LOGS/current-invocation"
            case "$wpid" in ''|*[!0-9]*) qr_wait_say "invalid invocation identity"; return 1 ;; esac
            seen=1; run=""; start="$(qr_wait_mtime "$QR_LOGS/current-invocation")"
            # The pointer may have been published after the no-lock sample.
            # Reconcile liveness; the identity check below keeps this waiter
            # pinned even if the new sample sees a different invocation.
            st=0; qr_lock_read || st=$?
          fi ;;
        *) wpid="$QR_LOCK_PID"; key="$QR_LOCK_INVOCATION"; seen=1; run=""
           if [ -z "$key" ]; then
             start="$(qr_wait_mtime "$(qr_lock_dir)/pid")"
             [ -n "$start" ] || start="$(qr_wait_mtime "$(qr_lock_dir)")"
           fi ;;
      esac
    fi
    # Never cache current.env for a pinned pending prepare: it may describe the previous run. Once concrete,
    # keep the folder even if the lock disappears; only this PID's lock or validated result may resolve it.
    if [ -z "$wpid" ]; then
      if [ "$st" = 0 ]; then run=""; else run="$(qr_wait_run_dir)"; fi
    elif [ "$QR_LOCK_PID" != "$wpid" ] || [ "$QR_LOCK_INVOCATION" != "$key" ]; then
      st=1
    elif [ -z "$run" ] && [ -d "${QR_LOCK_RUN:-}" ]; then
      run="$QR_LOCK_RUN"
    fi
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
        if res="$(qr_wait_result "$wpid" "$start" "$run" "$key")"; then
          [ -n "$run" ] || run="${res%%$'\n'*}"
          res="${res#*$'\n'}"
          terminal="${res%%$'\n'*}"
          read -r rc cmd verdict <<< "$terminal"
          qr_wait_say "the run ($cmd, pid ${wpid:-of the last run}) exited $rc"
          if [ -n "$verdict" ]; then
            [ "$terminal" = "$res" ] || printf '%s\n' "${res#*$'\n'}"
            [ "$rc" = 0 ] && [ "$verdict" = 0 ]; return $?
          fi
          [ -f "$run/summary.txt" ] && cat "$run/summary.txt"
          [ "$rc" = 0 ] && [ -f "$run/summary.txt" ] \
            && perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$(qr_wait_mtime "$run/summary.txt")" "${start:-0}" \
            && qr_wait_verdict "$run" "$cmd"
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
