#!/usr/bin/env bash
# Fault injection at result publication and wait observation boundaries. No editor or adb.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
QR_RUN_DIR="$tmp/run"
mkdir -p "$QR_RUN_DIR"
printf 'synthetic release summary\n' > "$QR_RUN_DIR/summary.txt"
qr_config() { :; }
qr_summary() { :; }
qr_prepare() { :; }

fails=0
check() {
  local label="$1"; shift
  if ( "$@" ) > "$tmp/out" 2> "$tmp/err"; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    cat "$tmp/out" "$tmp/err"
    fails=$((fails + 1))
  fi
}

compat_copy_failure() {
  QR_LOGS="$tmp/copy"
  cp() {
    case "$2" in
      "$QR_LOGS/last-result.$$" ) touch "$tmp/copy-attempted"; return 1 ;;
      *) command cp "$@" ;;
    esac
  }
  local run_rc=0 wait_rc=0
  ( qr_main prepare ) || run_rc=$?
  QUEST_WAIT_GRACE=0 qr_main wait || wait_rc=$?
  [ -f "$tmp/copy-attempted" ] && [ "$run_rc" = 0 ] && [ "$wait_rc" = 0 ] &&
    [ ! -e "$QR_LOGS/last-result" ] && grep -q 'warning:.*last-result' "$tmp/err" &&
    grep -q '^synthetic release summary$' "$tmp/out"
}

# Publish the same lock and pointer as a real producer, then freeze the report
# without last-result so a waiter cannot accidentally pass via the legacy path.
start_release() { qr_lock_acquire; }
finish_release() {
  qr_lock_result prepare 0 0 && rm -f "$QR_LOGS/last-result" && qr_lock_release
}

torn_lock() {
  local deletion="$1"
  QR_LOGS="$tmp/torn-$deletion"
  mkdir -p "$QR_LOGS"
  start_release || return 1
  if [ "$deletion" = equal ]; then
    touch -t 200001010000 "$QR_LOGS/run.lock/pid" "$QR_LOGS/current-invocation" || return 1
  fi
  cat() {
    command cat "$@" || return
    if [ "$*" = pid ] && [ . -ef "$QR_LOGS/run.lock" ]; then
      # The reader has the PID, but hasn't read the invocation key yet.
      # An older producer can delete the published directory in place.
      qr_lock_result prepare 0 0 && rm -f "$QR_LOGS/last-result" || exit 99
      if [ "$deletion" = paused ]; then
        rm -f invocation run_dir
      else
        rm -rf "$QR_LOGS/run.lock"
      fi
      touch "$QR_LOGS/tore-lock"
    fi
  }
  sleep() {
    [ "$deletion" = paused ] && [ -f "$QR_LOGS/tore-lock" ] && [ -f "$QR_LOGS/run.lock/pid" ] || exit 99
    rm -f "$QR_LOGS/run.lock/pid" && rmdir "$QR_LOGS/run.lock" || exit 99
  }
  local wait_rc=0
  QUEST_WAIT_GRACE=0 qr_main wait 1 || wait_rc=$?
  [ -f "$QR_LOGS/tore-lock" ] && [ "$wait_rc" = 0 ] &&
    grep -q '^synthetic release summary$' "$tmp/out"
}

legacy_with_old_pointer() {
  QR_LOGS="$tmp/legacy"
  mkdir -p "$QR_LOGS"
  start_release && finish_release || return 1
  touch -t 200001010000 "$QR_LOGS/current-invocation" || return 1
  # A genuine legacy owner can reuse the PID in an old keyed pointer.
  mkdir "$QR_LOGS/run.lock" && printf '%s\n' "$$" > "$QR_LOGS/run.lock/pid" &&
    printf '%s\n' "$QR_RUN_DIR" > "$QR_LOGS/run.lock/run_dir" || return 1
  real_lock_read && [ "$QR_LOCK_PID" = "$$" ] && [ -z "$QR_LOCK_INVOCATION" ]
}

eval "$(declare -f qr_lock_read | sed '1s/qr_lock_read/real_lock_read/')"
eval "$(declare -f qr_lock_snapshot | sed '1s/qr_lock_snapshot/real_lock_snapshot/')"
eval "$(declare -f qr_lock_pointer | sed '1s/qr_lock_pointer/real_lock_pointer/')"
start_during_wait() {
  QR_LOGS="$tmp/start"
  mkdir -p "$QR_LOGS"
  qr_lock_read() {
    local observed=0
    real_lock_read || observed=$?
    if [ "$observed" = 1 ] && [ ! -e "$tmp/started" ]; then
      # Publish after the no-lock observation but before the pointer read.
      start_release && touch "$tmp/started" || exit 99
    fi
    return "$observed"
  }
  sleep() {
    # The waiter must poll the live invocation before its result can exist.
    [ ! -e "$tmp/polled" ] && finish_release && touch "$tmp/polled" || exit 99
  }
  local wait_rc=0
  QUEST_WAIT_GRACE=0 qr_main wait || wait_rc=$?
  [ -f "$tmp/polled" ] && [ "$wait_rc" = 0 ] &&
    grep -q '^synthetic release summary$' "$tmp/out"
}

removed_waiter_cwd() {
  QR_LOGS="$tmp/cleanup"
  mkdir -p "$QR_LOGS" "$tmp/removed-worktree" && start_release || return 1
  cd "$tmp/removed-worktree" || return 1
  qr_lock_snapshot() {
    real_lock_snapshot "$@" || return $?
    # Cleanup removes the launch directory during a sample of its live lock.
    if [ -f "$QR_LOGS/first-poll" ]; then
      rm -rf "$tmp/removed-worktree" || exit 99
    fi
  }
  sleep() {
    if [ ! -f "$QR_LOGS/first-poll" ]; then
      touch "$QR_LOGS/first-poll" || exit 99
    elif [ ! -f "$QR_LOGS/second-poll" ]; then
      # The second sample must still see the live producer. Only now publish.
      [ ! -e "$tmp/removed-worktree" ] && [ -d "$QR_LOGS/run.lock" ] &&
        kill -0 "$$" && finish_release && touch "$QR_LOGS/second-poll" || exit 99
    else
      exit 99
    fi
  }
  local wait_rc=0
  QUEST_WAIT_GRACE=0 qr_main wait 1 || wait_rc=$?
  [ -f "$QR_LOGS/second-poll" ] && [ "$wait_rc" = 0 ] &&
    grep -q '^synthetic release summary$' "$tmp/out"
}

start_during_reconciliation() {
  local outcome="$1" wait_rc=0 polls=0 did_start=0 fake_now=0 samples=0 wait_minutes=1
  local dead_pid=2147483647
  # Use past, recent directory times so real_lock_read treats PID-less samples as live.
  local startup_stamp result_stamp teardown_stamp
  read -r startup_stamp result_stamp teardown_stamp < <(perl -MPOSIX=strftime -e '
    $now = time; print join(" ", map { strftime "%Y%m%d%H%M.%S", localtime($now - $_) } (30, 20, 10)), "\n";
  ')
  QR_LOGS="$tmp/pending-$outcome"
  QR_RUN_DIR="$QR_LOGS/run"
  mkdir -p "$QR_RUN_DIR" || return 1
  printf 'synthetic previous success\n' > "$QR_RUN_DIR/summary.txt" || return 1
  start_release && qr_lock_result prepare 0 0 && qr_lock_release || return 1
  local previous_key="$QR_INVOCATION"
  # A preceded the synthetic startup cutoff, including in backdated cases.
  touch -t 200001010000 "$QR_LOGS/current-invocation" || return 1
  if [ "$outcome" = first-legacy ] || [ "$outcome" = first-legacy-finished ]; then
    # With only legacy state, an abandoned startup must not reactivate last-result either.
    rm "$QR_LOGS/current-invocation" && printf 'QR_RUN_DIR=%q\n' "$QR_RUN_DIR" > "$QR_LOGS/current.env" || return 1
  elif [[ "$outcome" = first-keyed-stale-copy || "$outcome" = *vanished-stale ]]; then
    # This is A's normal compatibility copy, not B's terminal result.
    touch -t 200001010000 "$QR_LOGS/last-result" || return 1
    printf 'QR_RUN_DIR=%q\n' "$QR_RUN_DIR" > "$QR_LOGS/current.env" || return 1
  else
    rm "$QR_LOGS/last-result" || return 1
  fi
  case "$outcome" in
    first-keyed-legacy-race-vanished-owner*)
      # Reuse A's PID, but its pointer predates B's PID file and lock.
      mkdir "$QR_LOGS/run.lock" && printf '%s\n' "$$" > "$QR_LOGS/run.lock/pid" &&
        touch -t "$startup_stamp" "$QR_LOGS/run.lock/pid" "$QR_LOGS/run.lock" || return 1
      if [[ "$outcome" = *-equal* ]]; then
        touch -t "$startup_stamp" "$QR_LOGS/current-invocation" || return 1
      fi
      did_start=1 ;;
    first-keyed-legacy-race-created|first-keyed-legacy-race-in-snapshot|first-keyed-legacy-race-vanished-recheck) ;;
    first-keyed-legacy-race-vanished-keyed|first-keyed-legacy-race-vanished-mismatch)
      mkdir "$QR_LOGS/run.lock" && printf '%s\n' "$previous_key" > "$QR_LOGS/run.lock/invocation" || return 1
      did_start=1 ;;
    first-keyed-legacy-teardown|first-keyed-legacy-replaced|first-keyed-legacy-race-*)
      mkdir "$QR_LOGS/run.lock" && touch -t "$startup_stamp" "$QR_LOGS/run.lock" || return 1
      did_start=1 ;;
    first-*)
      mkdir "$QR_LOGS/run.lock" || return 1
      if [ "$outcome" = first-empty ]; then : > "$QR_LOGS/run.lock/pid" || return 1; fi
      did_start=1 ;;
    teardown)
      # An older keyed producer has finished and unlinked pid, but the key remains.
      start_release && qr_lock_result prepare 0 0 && rm -f "$QR_LOGS/last-result" "$QR_LOGS/run.lock/pid" || return 1
      did_start=1 ;;
    completed-deadline) wait_minutes=0 ;;
  esac
  cd() {
    if [ "$outcome" = first-keyed-legacy-race-vanished-mismatch ] && [ "$1" = "$QR_LOGS/run.lock" ]; then
      # FD 20 still pins A when the snapshot enters the PID-less successor B.
      mv "$1" "$QR_LOGS/retired" && mkdir "$1" && touch -t "$startup_stamp" "$1" || exit 99
    fi
    builtin cd "$@"
  }
  cat() {
    command cat "$@"; local cat_rc=$?
    if [ "$outcome" = first-keyed-legacy-race-vanished-early ] && [ "$*" = invocation ]; then
      touch "$QR_LOGS/read-owner" || exit 99
    fi
    if [[ "$outcome" = *vanished-owner* ]] && [ . -ef "$QR_LOGS/run.lock" ]; then
      # Finish just after sampling a numeric PID (or after its metadata checks).
      if { [ "$*" = run_dir ] && [[ "$outcome" = *-final ]]; } ||
         { [ "$*" = pid ] && [ "$cat_rc" = 0 ] && [[ "$outcome" != *-final ]]; }; then
        finish_legacy_in_place && touch "$QR_LOGS/vanished" || exit 99
        if [[ "$outcome" != *-retained-dir ]]; then rmdir "$QR_LOGS/run.lock" || exit 99; fi
        case "$outcome" in
          *-wrong-pid) printf 'pid=%s\ncmd=prepare\nrc=0\nrun=%s\nverdict=0\n' "$dead_pid" "$QR_RUN_DIR" > "$QR_LOGS/last-result" || exit 99 ;;
          *-old-result) touch -t "$startup_stamp" "$QR_LOGS/last-result" || exit 99 ;;
        esac
      fi
    elif [[ "$outcome" = first-keyed-legacy-race-vanished* && "$outcome" != *vanished-early ]] &&
         [ "$*" = pid ] && [ . -ef "$QR_LOGS/run.lock" ]; then
      # Publish and fully remove the lock on the second PID read, after the
      # pending stamp was sampled but before the final generation check.
      if [ -f "$QR_LOGS/read-pid" ]; then
        if [[ "$outcome" != *vanished-stale && "$outcome" != *vanished-keyed ]]; then
          finish_legacy_in_place || exit 99
        fi
        if [ "$outcome" = first-keyed-legacy-race-vanished-pid ]; then
          printf '%s\n' "$$"
        fi
        rm -rf "$QR_LOGS/run.lock" && touch "$QR_LOGS/vanished" || exit 99
      else
        touch "$QR_LOGS/read-pid" || exit 99
      fi
    fi
    return "$cat_rc"
  }
  qr_lock_pointer() {
    if [ "$outcome" = first-keyed-legacy-race-vanished-early ] && [ -f "$QR_LOGS/read-owner" ] &&
       [ . -ef "$QR_LOGS/run.lock" ]; then
      finish_legacy_in_place && rmdir "$QR_LOGS/run.lock" && touch "$QR_LOGS/vanished" || exit 99
    fi
    real_lock_pointer "$@"
  }
  qr_lock_snapshot() {
    real_lock_snapshot "$@" || return $?
    if [ "$samples:$outcome" = 1:first-keyed-legacy-race-in-snapshot ]; then
      # Finish before the sampled metadata even reaches the wait loop. The
      # startup cutoff must already belong to the pinned directory.
      finish_legacy_in_place || exit 99
    fi
  }
  qr_lock_read() {
    local observed=0
    samples=$((samples + 1))
    if [ "$samples" = 2 ] && [[ "$outcome" = completed* ]]; then
      # A has been read, but B publishes, fails and unlocks before reconciliation samples the lock.
      start_release && finish_failed_successor || exit 99
    fi
    if [ "$samples:$outcome" = 1:handoff ]; then
      start_release && finish_release && mkdir "$QR_LOGS/run.lock" || exit 99
      did_start=1
    fi
    case "$samples:$outcome" in
      1:first-keyed-legacy-race-replaced|2:first-keyed-legacy-race-previous)
        rmdir "$QR_LOGS/run.lock" || exit 99 ;;
    esac
    case "$samples:$outcome" in
      1:first-keyed-legacy-race-created|1:first-keyed-legacy-race-replaced|1:first-keyed-legacy-race-in-snapshot|2:first-keyed-legacy-race-previous|2:first-keyed-legacy-race-vanished-recheck)
        # On the original waiter this runs between FD open and the snapshot.
        # In the previous-result case the new generation starts after A's result.
        local stamp="$startup_stamp"
        if [ "$outcome" = first-keyed-legacy-race-previous ]; then stamp="$teardown_stamp"; fi
        mkdir "$QR_LOGS/run.lock" && touch -t "$stamp" "$QR_LOGS/run.lock" || exit 99
        did_start=1 ;;
    esac
    real_lock_read || observed=$?
    if [ "$samples:$outcome" = 2:live-after-recheck ]; then
      # B publishes only after reconciliation has sampled no lock. Its result
      # does not exist yet; the pointer cannot be judged using that sample.
      [ "$observed" = 1 ] && start_release || exit 99
    fi
    if [ "$samples:$outcome" = 2:stale ]; then
      # Reconciliation saw B's stale numeric owner. C publishes before wait can resolve B.
      [ "$observed" = 2 ] && [ "$QR_LOCK_PID" = "$dead_pid" ] && [ -n "$QR_LOCK_INVOCATION" ] &&
        rm -rf "$QR_LOGS/run.lock" && publish_third_release || exit 99
    fi
    if [ "$observed" = 1 ] && [ "$did_start" = 0 ]; then
      # A successor starts after the no-lock sample, but the pointer still names the old result.
      if [ "$outcome" = before-pointer ] || [ "$outcome" = stale ]; then
        mv "$QR_LOGS/current-invocation" "$QR_LOGS/previous-pointer" && start_release &&
          mv "$QR_LOGS/current-invocation" "$QR_LOGS/next-pointer" &&
          mv "$QR_LOGS/previous-pointer" "$QR_LOGS/current-invocation" || exit 99
        if [ "$outcome" = stale ]; then
          printf '%s\n' "$dead_pid" > "$QR_LOGS/run.lock/pid" || exit 99
        fi
      elif [[ "$outcome" != completed* && "$outcome" != live-after-recheck &&
              "$outcome" != first-keyed-legacy-race-vanished-recheck ]]; then
        mkdir "$QR_LOGS/run.lock" || exit 99
      fi
      did_start=1
    fi
    return "$observed"
  }
  qr_wait_now() { echo "$fake_now"; }
  sleep() {
    polls=$((polls + 1)); fake_now=$((fake_now + 20))
    [ "$polls" -le 3 ] || exit 99
    printf '%s\n' "$polls" > "$QR_LOGS/polls" || exit 99
    case "$polls:$outcome" in
      1:failure|1:fast|1:first-fast)
        rmdir "$QR_LOGS/run.lock" && start_release || exit 99
        if [ "$outcome" != failure ]; then finish_failed_successor || exit 99; fi ;;
      2:failure)
        finish_failed_successor || exit 99 ;;
      1:before-pointer)
        mv "$QR_LOGS/next-pointer" "$QR_LOGS/current-invocation" && finish_failed_successor &&
          publish_third_release || exit 99 ;;
      1:completed) publish_third_release || exit 99 ;;
      1:live-after-recheck) finish_failed_successor || exit 99 ;;
      1:teardown) rm -rf "$QR_LOGS/run.lock" || exit 99 ;;
      1:first-legacy-finished|1:first-keyed-legacy-finished|1:first-keyed-legacy-early)
        rmdir "$QR_LOGS/run.lock" && qr_lock_acquire 0 || exit 99
        if [ "$outcome" = first-keyed-legacy-early ]; then
          ( QR_RUN_DIR=""; qr_lock_result prepare 1 ) && qr_lock_release || exit 99
        else
          printf 'QR_RUN_DIR=%q\n' "$QR_RUN_DIR" > "$QR_LOGS/current.env" && finish_failed_successor || exit 99
        fi
        # Strict freshness should not depend on timestamp resolution.
        perl -e 'utime time + 2, time + 2, $ARGV[0] or die $!' "$QR_LOGS/last-result" || exit 99 ;;
      1:first-keyed-legacy-race-in-snapshot|*:first-keyed-legacy-race-vanished*) ;;
      1:first-keyed-legacy-teardown|1:first-keyed-legacy-replaced|1:first-keyed-legacy-race-*)
        finish_legacy_in_place || exit 99
        if [ "$outcome" = first-keyed-legacy-replaced ]; then
          # Leave no sampled gap but present a different pending lock generation.
          local lock="$QR_LOGS/run.lock"
          rmdir "$lock" && mkdir "$lock" && touch -t "$teardown_stamp" "$lock" || exit 99
        fi ;;
      2:first-keyed-legacy-teardown|2:first-keyed-legacy-replaced|2:first-keyed-legacy-race-*)
        rmdir "$QR_LOGS/run.lock" || exit 99 ;;
      1:unpublished|1:first-unpublished|1:first-empty|1:first-legacy|1:first-keyed-stale-copy|1:handoff)
        # An abandoned startup must not send the waiter back to the old pointer.
        rm -f "$QR_LOGS/run.lock/pid" && rmdir "$QR_LOGS/run.lock" || exit 99 ;;
    esac
  }
  finish_legacy_in_place() {
    # Publish before unlinking the PID and advancing the directory timestamp.
    local lock="$QR_LOGS/run.lock"
    printf '%s\n' "$$" > "$lock/pid" && printf 'QR_RUN_DIR=%q\n' "$QR_RUN_DIR" > "$QR_LOGS/current.env" &&
      printf 'synthetic successor failed\n' > "$QR_RUN_DIR/summary.txt" &&
      ( QR_INVOCATION="" QR_LOCK_HELD=1; qr_lock_result prepare 1 0 ) &&
      touch -t "$result_stamp" "$QR_LOGS/last-result" && rm "$lock/pid" && touch -t "$teardown_stamp" "$lock"
  }
  finish_failed_successor() {
    printf 'synthetic successor failed\n' > "$QR_RUN_DIR/summary.txt" &&
      qr_lock_result prepare 1 0 && qr_lock_release
  }
  publish_third_release() {
    printf 'synthetic third success\n' > "$QR_RUN_DIR/summary.txt" && start_release && finish_release
  }
  QUEST_WAIT_GRACE=0 qr_main wait "$wait_minutes" || wait_rc=$?
  if [[ "$outcome" != teardown && "$outcome" != *vanished-keyed ]]; then
    ! grep -Eq '^synthetic (previous|third) success$' "$tmp/out" || return 1
  fi
  case "$outcome" in
    failure|fast|first-fast|before-pointer|completed*|live-after-recheck)
      [ "$wait_rc" = 1 ] && grep -q '^synthetic successor failed$' "$tmp/out" &&
        ! grep -qF "$previous_key" "$QR_LOGS/current-invocation" ;;
    stale)
      [ "$wait_rc" = 1 ] && [ ! -s "$tmp/out" ] &&
        grep -Fq "(pid $dead_pid) ended (lock gone) without writing its result" "$tmp/err" ;;
    teardown)
      [ "$wait_rc" = 0 ] && [ "$(cat "$QR_LOGS/polls")" = 1 ] && grep -q '^synthetic previous success$' "$tmp/out" ;;
    first-keyed-legacy-replaced|first-keyed-legacy-race-previous)
      [ "$wait_rc" = 124 ] && [ ! -s "$tmp/out" ] && grep -Fq "$previous_key" "$QR_LOGS/current-invocation" ;;
    first-keyed-legacy-race-vanished-keyed)
      [ -f "$QR_LOGS/vanished" ] && [ "$wait_rc" = 0 ] && grep -q '^synthetic previous success$' "$tmp/out" ;;
    first-keyed-legacy-race-vanished-stale)
      [ -f "$QR_LOGS/vanished" ] && [ "$wait_rc" = 124 ] && [ ! -s "$tmp/out" ] ;;
    first-keyed-legacy-race-vanished-owner-wrong-pid|first-keyed-legacy-race-vanished-owner-old-result)
      [ -f "$QR_LOGS/vanished" ] && [ "$wait_rc" = 1 ] && [ ! -s "$tmp/out" ] &&
        grep -Fq "(pid $$) ended (lock gone) without writing its result" "$tmp/err" ;;
    first-keyed-legacy-race-vanished*)
      [ -f "$QR_LOGS/vanished" ] && [ ! -f "$QR_LOGS/polls" ] && [ "$wait_rc" = 1 ] && grep -q 'exited 1' "$tmp/err" &&
        grep -q '^synthetic successor failed$' "$tmp/out" && grep -qF "$previous_key" "$QR_LOGS/current-invocation" ;;
    first-keyed-legacy-teardown|first-keyed-legacy-race-*)
      [ "$wait_rc" = 1 ] && [ "$(cat "$QR_LOGS/polls")" = 2 ] && grep -q 'exited 1' "$tmp/err" &&
        grep -q '^synthetic successor failed$' "$tmp/out" && grep -Fq "$previous_key" "$QR_LOGS/current-invocation" ;;
    first-legacy-finished|first-keyed-legacy-finished)
      [ "$wait_rc" = 1 ] && grep -q '^synthetic successor failed$' "$tmp/out" &&
        { [ "$outcome" = first-legacy-finished ] || grep -qF "$previous_key" "$QR_LOGS/current-invocation"; } ;;
    first-keyed-legacy-early)
      [ "$wait_rc" = 1 ] && [ ! -s "$tmp/out" ] && grep -q 'exited 1' "$tmp/err" &&
        grep -qF "$previous_key" "$QR_LOGS/current-invocation" ;;
    unpublished|first-unpublished|first-empty|first-legacy|first-keyed-stale-copy|handoff)
      [ "$wait_rc" = 124 ] && [ "$(cat "$QR_LOGS/polls")" = 3 ] && grep -q 'timed out after 1 min' "$tmp/err" ;;
  esac
}

pending_keyed_copy_failure() {
  local timing="$1" cutoff=200001010001
  QR_LOGS="$tmp/pending-copy-$timing"
  local lock="$QR_LOGS/run.lock" wait_rc=0
  QR_RUN_DIR="$QR_LOGS/run"
  mkdir -p "$QR_RUN_DIR" || return 1
  printf 'synthetic previous success\n' > "$QR_RUN_DIR/summary.txt" || return 1
  start_release && qr_lock_result prepare 0 0 && qr_lock_release || return 1
  touch -t 200001010000 "$QR_LOGS/current-invocation" "$QR_LOGS/last-result" || return 1
  mkdir "$lock" && touch -t "$cutoff" "$lock" || return 1
  if [ "$timing" = predecessor ]; then
    touch -t "$cutoff" "$QR_LOGS/current-invocation" || return 1
  fi
  cp() {
    [ "$2" = "$QR_LOGS/last-result.$$" ] || { command cp "$@"; return; }
    touch "$QR_LOGS/copy-attempted" || exit 99
    return 1
  }
  cat() {
    command cat "$@"; local status=$?
    if [ "$*" = invocation ] && [ . -ef "$lock" ]; then
      # Publish after both owner reads missed, but before wait samples the pointer.
      if [ "$timing" = predecessor ]; then
        rmdir "$lock" && touch "$QR_LOGS/vanished" || exit 99
        return "$status"
      fi
      local invocation_dir
      invocation_dir="$(mktemp -d "$QR_LOGS/invocations/run.XXXXXXXXXX")" || exit 99
      QR_INVOCATION="${invocation_dir##*/}"; QR_LOCK_HELD=1
      printf '%s\n' "$QR_INVOCATION" > "$lock/invocation" && printf '%s\n' "$$" > "$lock/pid" &&
        printf '%s %s\n' "$$" "$QR_INVOCATION" > "$QR_LOGS/new-pointer" &&
        { [ "$timing" != equal ] || touch -t "$cutoff" "$QR_LOGS/new-pointer"; } &&
        mv "$QR_LOGS/new-pointer" "$QR_LOGS/current-invocation" &&
        printf 'synthetic keyed successor\n' > "$QR_RUN_DIR/summary.txt" &&
        qr_lock_result prepare 0 0 && qr_lock_release || exit 99
    fi
    return "$status"
  }
  QUEST_WAIT_GRACE=0 qr_main wait 0 || wait_rc=$?
  if [ "$timing" = predecessor ]; then
    [ -f "$QR_LOGS/vanished" ] && [ "$wait_rc" = 124 ] && [ ! -s "$tmp/out" ]; return $?
  fi
  [ -f "$QR_LOGS/copy-attempted" ] && grep -q '^synthetic previous success$' "$QR_LOGS/last-result" &&
    [ "$wait_rc" = 0 ] && grep -q '^synthetic keyed successor$' "$tmp/out" &&
    ! grep -q '^synthetic previous success$' "$tmp/out"
}

pending_legacy_retry() {
  QR_LOGS="$tmp/pending-retry"
  local lock="$QR_LOGS/run.lock" wait_rc=0 fake_now=0 cutoff result_stamp
  read -r cutoff result_stamp < <(perl -MPOSIX=strftime -e '
    $now = time; print join(" ", map { strftime "%Y%m%d%H%M.%S", localtime($now - $_) } (30, 15)), "\n";
  ')
  QR_RUN_DIR="$QR_LOGS/run"
  mkdir -p "$lock" "$QR_RUN_DIR" && : > "$lock/pid" && touch -t "$cutoff" "$lock" || return 1
  cat() {
    command cat "$@" || return
    if [ "$*" = pid ] && [ . -ef "$lock" ]; then
      if [ ! -s pid ]; then
        printf '%s\n' "$$" > pid || exit 99
      else
        printf 'synthetic legacy retry failure\n' > "$QR_RUN_DIR/summary.txt" &&
          printf 'QR_RUN_DIR=%q\n' "$QR_RUN_DIR" > "$QR_LOGS/current.env" &&
          ( QR_INVOCATION='' QR_LOCK_HELD=1; qr_lock_result prepare 1 0 ) &&
          touch -t "$result_stamp" "$QR_LOGS/last-result" &&
          rm pid || exit 99
      fi
    fi
  }
  qr_wait_now() { echo "$fake_now"; }
  sleep() { rmdir "$lock" || exit 99; fake_now=60; }
  QUEST_WAIT_GRACE=0 qr_main wait 1 || wait_rc=$?
  [ "$wait_rc" = 1 ] && [ ! -d "$lock" ] && grep -q 'exited 1' "$tmp/err" &&
    grep -q '^synthetic legacy retry failure$' "$tmp/out"
}

check 'compatibility copy failure does not change the published outcome' compat_copy_failure
check 'a pointer published during pending sampling resolves without a compatibility copy' pending_keyed_copy_failure newer
check 'an equal-time publication during pending sampling resolves without a compatibility copy' pending_keyed_copy_failure equal
check 'an unchanged equal-time pointer cannot resolve an abandoned pending lock' pending_keyed_copy_failure predecessor
check 'a same-generation legacy retry keeps the initial pending cutoff' pending_legacy_retry
check 'keyed teardown retains the key when pointer and PID timestamps are equal' torn_lock equal
check 'deletion between metadata reads does not pin a legacy owner' torn_lock complete
check 'deletion paused before removing the directory does not pin a legacy owner' torn_lock paused
check 'an old keyed pointer does not relabel a legacy lock with the same PID' legacy_with_old_pointer
check 'a newly published invocation is waited on, not reported as ended' start_during_wait
check 'an unpublished successor overrides a provisional previous result' start_during_reconciliation failure
check 'a successor that completes between polls replaces the provisional result' start_during_reconciliation fast
check 'a live owner seen at reconciliation stays pinned after a third release' start_during_reconciliation before-pointer
check 'a stale owner seen at reconciliation fails if its keyed result is missing' start_during_reconciliation stale
check 'a successor that completes before reconciliation overrides the sampled pointer' start_during_reconciliation completed
check 'the final poll can report a successor that completed during reconciliation' start_during_reconciliation completed-deadline
check 'retrying an unpublished successor is bounded and never returns the old result' start_during_reconciliation unpublished
check 'a fresh lock seen on the first poll stays pending after disappearing' start_during_reconciliation first-unpublished
check 'an empty legacy PID file keeps an abandoned startup pending' start_during_reconciliation first-empty
check 'an abandoned startup also suppresses a historical legacy result' start_during_reconciliation first-legacy
check 'a first-poll pending lock can resolve through a newly published key' start_during_reconciliation first-fast
check 'a legacy startup can publish a fresh result and unlock between polls' start_during_reconciliation first-legacy-finished
check 'a pointer published before an abandoned startup does not certify it' start_during_reconciliation handoff
check 'a PID-less keyed teardown can still resolve its completed release' start_during_reconciliation teardown
check 'a new pointer after reconciliation needs a fresh lock sample' start_during_reconciliation live-after-recheck
check 'a keyed compatibility copy cannot resolve a later pending startup' start_during_reconciliation first-keyed-stale-copy
check 'a fresh legacy result can follow an unchanged keyed pointer' start_during_reconciliation first-keyed-legacy-finished
check 'a fresh legacy failure before prepare needs no folder or new pointer' start_during_reconciliation first-keyed-legacy-early
check 'a PID-less legacy teardown preserves the observed startup boundary' start_during_reconciliation first-keyed-legacy-teardown
check 'a replacement PID-less lock cannot claim the preceding legacy result' start_during_reconciliation first-keyed-legacy-replaced
check 'a legacy lock created after FD open can still report its own result' start_during_reconciliation first-keyed-legacy-race-created
check 'a legacy lock replaced after FD open can still report its own result' start_during_reconciliation first-keyed-legacy-race-replaced
check 'a replacement during FD sampling rejects the preceding legacy result' start_during_reconciliation first-keyed-legacy-race-previous
check 'a waiter survives removal of its launch directory while the producer is live' removed_waiter_cwd
check 'a legacy result published before the snapshot returns keeps its startup cutoff' start_during_reconciliation first-keyed-legacy-race-in-snapshot
check 'a pending legacy lock that vanishes during the snapshot does not fall back to the previous success' start_during_reconciliation first-keyed-legacy-race-vanished
check 'a pending legacy lock that vanishes during pointer reconciliation suppresses the previous success' start_during_reconciliation first-keyed-legacy-race-vanished-recheck
check 'a vanished pending lock cannot claim the preceding compatibility result' start_during_reconciliation first-keyed-legacy-race-vanished-stale
check 'a PID appearing on recheck does not erase pending evidence if the lock vanished' start_during_reconciliation first-keyed-legacy-race-vanished-pid
check 'a legacy result written before the pointer read uses the earlier generation cutoff' start_during_reconciliation first-keyed-legacy-race-vanished-early
check 'a keyed teardown that vanishes during sampling retains its own result' start_during_reconciliation first-keyed-legacy-race-vanished-keyed
check 'a legacy owner that unlinks its sampled PID still reports its failure' start_during_reconciliation first-keyed-legacy-race-vanished-owner
check 'a vanished legacy owner cannot inherit an equal-time pointer for its reused PID' start_during_reconciliation first-keyed-legacy-race-vanished-owner-equal
check 'a legacy owner cannot inherit an equal-time pointer before teardown either' start_during_reconciliation first-keyed-legacy-race-vanished-owner-equal-final
check 'a legacy owner that unlocks after the PID checks still reports its failure' start_during_reconciliation first-keyed-legacy-race-vanished-owner-final
check 'a PID-less retry of the same legacy lock retains the sampled numeric owner' start_during_reconciliation first-keyed-legacy-race-vanished-owner-retained-dir
check 'a vanished legacy owner rejects a fresh result for another PID' start_during_reconciliation first-keyed-legacy-race-vanished-owner-wrong-pid
check 'a vanished legacy owner rejects a stale result for the same PID' start_during_reconciliation first-keyed-legacy-race-vanished-owner-old-result
check 'a vanished successor entered after FD open overrides the preceding keyed success' start_during_reconciliation first-keyed-legacy-race-vanished-mismatch
[ "$fails" = 0 ]
