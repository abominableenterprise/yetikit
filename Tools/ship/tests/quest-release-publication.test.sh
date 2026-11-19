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

start_without_identity() {
  local outcome="$1" wait_rc=0 polls=0 did_start=0 fake_now=0
  QR_LOGS="$tmp/pending-$outcome"
  mkdir -p "$QR_LOGS"
  start_release && finish_release || return 1
  local previous_key="$QR_INVOCATION"
  qr_lock_read() {
    local observed=0
    real_lock_read || observed=$?
    if [ "$observed" = 1 ] && [ "$did_start" = 0 ]; then
      # A successor starts after the no-lock sample, but the pointer still names the old result.
      mkdir "$QR_LOGS/run.lock" || exit 99
      did_start=1
    fi
    return "$observed"
  }
  qr_wait_now() { echo "$fake_now"; }
  sleep() {
    polls=$((polls + 1)); fake_now=$((fake_now + 20))
    case "$polls:$outcome" in
      1:failure|1:fast)
        rmdir "$QR_LOGS/run.lock" && start_release || exit 99
        if [ "$outcome" = fast ]; then finish_failed_successor || exit 99; fi ;;
      2:failure)
        finish_failed_successor || exit 99 ;;
      1:unpublished)
        # An abandoned startup must not send the waiter back to the old pointer.
        rmdir "$QR_LOGS/run.lock" || exit 99 ;;
    esac
  }
  finish_failed_successor() {
    printf 'synthetic successor failed\n' > "$QR_RUN_DIR/summary.txt" &&
      qr_lock_result prepare 1 0 && qr_lock_release
  }
  QUEST_WAIT_GRACE=0 qr_main wait 1 || wait_rc=$?
  ! grep -q '^synthetic release summary$' "$tmp/out" || return 1
  case "$outcome" in
    failure|fast)
      [ "$wait_rc" = 1 ] && grep -q '^synthetic successor failed$' "$tmp/out" &&
        ! grep -qF "$previous_key" "$QR_LOGS/current-invocation" ;;
    unpublished)
      [ "$wait_rc" = 124 ] && grep -q 'timed out after 1 min' "$tmp/err" ;;
  esac
}

check 'compatibility copy failure does not change the published outcome' compat_copy_failure
check 'deletion between metadata reads does not pin a legacy owner' torn_lock complete
check 'deletion paused before removing the directory does not pin a legacy owner' torn_lock paused
check 'an old keyed pointer does not relabel a legacy lock with the same PID' legacy_with_old_pointer
check 'a newly published invocation is waited on, not reported as ended' start_during_wait
check 'an unpublished successor overrides a provisional previous result' start_without_identity failure
check 'a successor that completes between polls replaces the provisional result' start_without_identity fast
check 'retrying an unpublished successor is bounded and never returns the old result' start_without_identity unpublished
[ "$fails" = 0 ]
