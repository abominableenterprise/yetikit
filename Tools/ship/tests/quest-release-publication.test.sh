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
  QR_LOGS="$tmp/torn"
  mkdir -p "$QR_LOGS"
  start_release || return 1
  cat() {
    command cat "$@" || return
    if [ "$*" = pid ] && [ . -ef "$QR_LOGS/run.lock" ]; then
      # The reader has the PID, but hasn't read the invocation key yet.
      # An older producer can delete the published directory in place.
      qr_lock_result prepare 0 0 && rm -rf "$QR_LOGS/run.lock" "$QR_LOGS/last-result" && touch "$tmp/tore-lock"
    fi
  }
  local wait_rc=0
  QUEST_WAIT_GRACE=0 qr_main wait || wait_rc=$?
  [ -f "$tmp/tore-lock" ] && [ "$wait_rc" = 0 ] &&
    grep -q '^synthetic release summary$' "$tmp/out"
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

check 'compatibility copy failure does not change the published outcome' compat_copy_failure
check 'deletion between metadata reads does not pin a legacy owner' torn_lock
check 'a newly published invocation is waited on, not reported as ended' start_during_wait
[ "$fails" = 0 ]
