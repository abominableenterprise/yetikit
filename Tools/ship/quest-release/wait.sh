# shellcheck shell=bash
# quest-release `wait [minutes]`: watch the current lock generation, then print its frozen report and return
# 0 for success, 1 for failure or missing result, 124 on timeout with the logs' last lines.
# Read-only: takes no lock and writes nothing. Sourced by Tools/ship/quest-release.sh; Bash 3.2 compatible.

qr_wait_now() { date +%s; }
qr_wait_say() { printf '[quest-release] wait: %s\n' "$*" >&2; }

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
# $1 PID, $2 start time, $3 run folder, $4 invocation key, $5 pending legacy startup (optional).
# Emits folder, rc, command, frozen verdict (blank for a legacy mutable summary), then the optional report.
qr_wait_result() {
  local f="$QR_LOGS/last-result" record header p rc cmd run verdict marker=$'\nreport:'
  if [ -n "$4" ]; then
    [[ "$4" =~ ^run\.[a-zA-Z0-9]{10}$ ]] || return 1
    f="$QR_LOGS/invocations/$4/result"
  fi
  if [ "${5:-}" = pending ]; then
    # Read and stat the same file so an atomic replacement cannot lend its
    # fresh timestamp to an older record.
    record="$(perl -MTime::HiRes=stat -e '
      open my $result, "<", $ARGV[0] or exit 1;
      my @s = stat $result; exit 1 unless @s && $s[9] > $ARGV[1];
      local $/; print <$result>;
    ' "$f" "$2")" || return 1
  else
    record="$(cat "$f" 2>/dev/null)" || return 1
  fi
  if [[ "$record" != *"$marker"* ]]; then marker=$'\nlist-summary:'; fi
  header="${record%%"$marker"*}"
  p="$(printf '%s\n' "$header" | sed -n 's/^pid=//p')"
  rc="$(printf '%s\n' "$header" | sed -n 's/^rc=//p')"
  cmd="$(printf '%s\n' "$header" | sed -n 's/^cmd=//p')"
  run="$(printf '%s\n' "$header" | sed -n 's/^run=//p')"
  verdict="$(printf '%s\n' "$header" | sed -n 's/^verdict=//p')"
  [ -z "$1" ] || [ "$p" = "$1" ] || return 1
  [ -n "$4" ] || [ "${5:-}" = pending ] ||
    perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$(qr_lock_mtime "$f")" "${2:-0}" || return 1
  if [ "${5:-}" = pending ]; then
    [[ "$p" =~ ^[1-9][0-9]*$ && "$rc" =~ ^(0|[1-9][0-9]*)$ ]] && [ -n "$cmd" ] || return 1
    [ -n "$run" ] || [ "$rc" != 0 ] || return 1
  fi
  [ "$run" = "$3" ] \
    || { [ -z "$3" ] && { [ -n "$4" ] || { [ -n "$1" ] && [ -n "$2" ]; }; }; } \
    || { [ -z "$run" ] && [ "$rc" != 0 ]; } || return 1
  if [ "$header" != "$record" ] && [ -z "$verdict" ]; then verdict="$rc"; fi # old list report
  [ -z "$4" ] || [ "$verdict" = 0 ] || [ "$verdict" = 1 ] || return 1
  printf '%s\n%s %s %s\n' "$run" "$rc" "$cmd" "$verdict"
  if [ "$header" != "$record" ]; then printf '%s' "${record#*"$marker"}"; fi
}

# Open before sampling so a directory that vanishes during the read cannot
# be confused with a replacement that reuses its inode.
qr_wait_read_lock() {
  sample_open=0
  if { exec 18< "$(qr_lock_dir)"; } 2>/dev/null; then sample_open=1; fi
  qr_lock_read
}

qr_wait() (
  local minutes="${1:-45}" poll="${QUEST_WAIT_POLL:-5}" grace="${QUEST_WAIT_GRACE:-15}" t0 now deadline
  local last_line seen=0 start="" run="" st wpid="" key="" res terminal rc cmd verdict
  local pointer="$QR_LOGS/current-invocation" pointer_pid pointer_key sampled_pid sampled_key
  local pending=0 superseded_pid="" superseded_key="" retry_pointer legacy_start="" legacy_lock=""
  local sample_open=0 stamp QR_WAIT_SAMPLE=1
  case "$minutes" in ''|*[!0-9]*) qr_wait_say "usage: wait [minutes]"; return 2 ;; esac
  minutes=$((10#$minutes))
  t0="$(qr_wait_now)"; deadline=$((t0 + minutes * 60)); last_line="$t0"
  while :; do
    retry_pointer=0; res=""
    st=0; qr_wait_read_lock || st=$?
    if [ -z "$wpid" ] && [ "$st" != 0 ] && ! [[ "$QR_LOCK_PID" =~ ^[0-9]+$ ]]; then
      if [ $(( $(qr_wait_now) - t0 )) -ge "$grace" ] && [ -f "$pointer" ]; then
        # A run can finish between samples, without ever preparing a folder. Use its
        # published identity, not historical current.env, to select its result.
        if ! read -r pointer_pid pointer_key 2>/dev/null < "$pointer"; then
          retry_pointer=1
        elif ! [[ "$pointer_pid" =~ ^[0-9]+$ ]]; then
          qr_wait_say "invalid invocation identity"; return 1
        elif [ "$pending" = 0 ] || [ "$pointer_pid" != "$superseded_pid" ] || [ "$pointer_key" != "$superseded_key" ]; then
          sampled_pid="$pointer_pid"; sampled_key="$pointer_key"
          st=0; qr_wait_read_lock || st=$?
          if [ "$st" != 0 ] && ! [[ "$QR_LOCK_PID" =~ ^[0-9]+$ ]]; then
            # A successor may have started or finished during reconciliation.
            # Recheck a changed pointer's lock, but keep the final poll bounded.
            start="$(qr_lock_mtime "$pointer")"
            if read -r pointer_pid pointer_key 2>/dev/null < "$pointer" && [[ "$pointer_pid" =~ ^[0-9]+$ ]] &&
               { [ "$pending" = 0 ] || [ "$pointer_pid" != "$superseded_pid" ] || [ "$pointer_key" != "$superseded_key" ]; }; then
              if [ "$pointer_pid" != "$sampled_pid" ] || [ "$pointer_key" != "$sampled_key" ]; then
                st=0; qr_wait_read_lock || st=$?
              fi
              if [ "$st" != 0 ] && ! [[ "$QR_LOCK_PID" =~ ^[0-9]+$ ]]; then
                wpid="$pointer_pid"; key="$pointer_key"; seen=1; run=""
              fi
            else
              retry_pointer=1
            fi
          fi
        fi
      fi
    fi
    # Either sample can pin the first numeric owner, including a stale lock. Keep its
    # start and run folder too (prepare may fill in the folder while it holds the lock).
    if [ -z "$wpid" ] && [[ "$QR_LOCK_PID" =~ ^[0-9]+$ ]]; then
      wpid="$QR_LOCK_PID"; key="$QR_LOCK_INVOCATION"; seen=1; run=""
      if [ -z "$key" ]; then
        start="$(qr_lock_mtime "$(qr_lock_dir)/pid")"
        [ -n "$start" ] || start="$(qr_lock_mtime "$(qr_lock_dir)")"
      fi
    elif [ -z "$wpid" ] && { [ "$st" = 0 ] || { [ "$pending" = 1 ] && [ -n "$QR_LOCK_UNPUBLISHED_ID" ]; }; }; then
      pending=1
      superseded_pid="$QR_LOCK_PREV_PID"; superseded_key="$QR_LOCK_PREV_INVOCATION"
      # Directory mtime changes when legacy teardown unlinks the PID. Keep
      # the first timestamp only while sampling the same pinned directory.
      # Holding it open prevents inode reuse from disguising a replacement.
      if [ -z "$legacy_lock" ] || [ "$QR_LOCK_UNPUBLISHED_ID" != "$legacy_lock" ]; then
        legacy_start="$QR_LOCK_UNPUBLISHED_AT"; legacy_lock=""
        if [ "$sample_open" = 1 ]; then
          stamp="$(qr_lock_stamp <&18)"
          if [ -n "$QR_LOCK_UNPUBLISHED_ID" ] && [ "${stamp#* }" = "$QR_LOCK_UNPUBLISHED_ID" ]; then
            exec 19<&18
            legacy_lock="$QR_LOCK_UNPUBLISHED_ID"
          fi
        fi
      fi
      # Older keyed producers removed their lock files in place. A retained
      # key with its own result proves teardown, not a new pending startup.
      if [ -n "$superseded_key" ] && [ "$QR_LOCK_INVOCATION" = "$superseded_key" ] &&
         qr_wait_result "$superseded_pid" "" "" "$superseded_key" >/dev/null; then
        superseded_pid=""; superseded_key=""
      fi
    elif [ -z "$wpid" ] && [ "$pending" = 1 ] && [ "$retry_pointer" = 0 ] &&
         [ -n "$legacy_start" ] && [ "$st" = 1 ] && [ $(( $(qr_wait_now) - t0 )) -ge "$grace" ]; then
      # Legacy producers leave the keyed pointer untouched. Only a result
      # newer than the pending lock can resolve it, even without a run folder.
      if res="$(qr_wait_result "" "$legacy_start" "$(qr_wait_run_dir)" "" pending)"; then
        start="$legacy_start"; seen=1; run="${res%%$'\n'*}"
      fi
    fi
    exec 18<&-
    # Never cache current.env for a pinned pending prepare: it may describe the previous run. Once concrete,
    # keep the folder even if the lock disappears; only this PID's lock or validated result may resolve it.
    if [ -z "$wpid" ]; then
      if [ "$seen" = 0 ]; then
        if [ "$st" = 0 ] || [ "$pending" = 1 ] || [ "$retry_pointer" = 1 ]; then run=""; else run="$(qr_wait_run_dir)"; fi
      fi
    elif [ "$QR_LOCK_PID" != "$wpid" ] || [ "$QR_LOCK_INVOCATION" != "$key" ]; then
      st=1
    elif [ -z "$run" ] && [ -d "${QR_LOCK_RUN:-}" ]; then
      run="$QR_LOCK_RUN"
    fi
    now="$(qr_wait_now)"
    if [ "$st" != 0 ] && { [ "$seen" = 1 ] || { [ "$pending" = 0 ] && [ "$retry_pointer" = 0 ]; }; }; then
      # No lock at all: the run is over, or (just after a nohup start) not locked yet; after a short grace the run's
      # start is when prepare wrote current.env.
      if [ "$seen" = 0 ] && [ $((now - t0)) -ge "$grace" ]; then
        [ -n "$run" ] || { qr_wait_say "no quest-release run in $QR_LOGS"; return 1; }
        start="$(qr_lock_mtime "$(qr_state_file)")"; seen=1
      fi
      if [ "$seen" = 1 ]; then
        # Without an observed lock, current.env supplies the earliest valid result time and the run identity.
        if [ -n "$res" ] || res="$(qr_wait_result "$wpid" "$start" "$run" "$key")"; then
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
            && perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$(qr_lock_mtime "$run/summary.txt")" "${start:-0}" \
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
)
