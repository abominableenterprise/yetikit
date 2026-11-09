# shellcheck shell=bash
# Process handshakes, not elapsed-time assertions. The runner bounds a broken test.
. "$(dirname "$0")/lib/quest-release-fixture.sh"

qr_test_no_gtimeout() {
  command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = gtimeout ]; then return 1; fi
    builtin command "$@"
  }
}

# Never finishes naturally, so a termination marker proves the real timebox fired.
qr_test_block_until_term() {
  local marker="$1" child=''
  trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; : > "$marker.terminated"; exit 143' TERM
  : > "$marker.started"
  while :; do command sleep 3600 & child=$!; wait "$child"; done
}

qr_test_watchdog_timeout() (
  qr_test_no_gtimeout
  r=0; qr_timebox 1 qr_test_block_until_term "$tmp/watchdog" 2> "$tmp/timebox.err" || r=$?
  [ "$r" = 124 ] && [ -f "$tmp/watchdog.started" ] &&
    [ -f "$tmp/watchdog.terminated" ] && grep -q 'timed out after 1s' "$tmp/timebox.err"
)

qr_test_watchdog_cleanup() (
  qr_test_no_gtimeout
  # Record only sleeps owned by this invocation, not unrelated process-table matches.
  sleep() {
    local child marker
    command sleep "$1" & child=$!
    marker="$tmp/watchdog-sleep-$child"
    trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; : > "$marker.done"; exit 0' TERM
    printf '%s\n' "$child" > "$marker.pid"
    wait "$child"
    : > "$marker.done"
  }
  qr_timebox 4321 true
  r=0; qr_timebox 1 qr_test_block_until_term "$tmp/watchdog-cleanup" 2>/dev/null || r=$?
  [ "$r" = 124 ] || exit 1
  found=0
  for file in "$tmp"/watchdog-sleep-*.pid; do
    [ -f "$file" ] || continue
    found=1
    child="$(cat "$file")"
    qr_fixture_wait_ready "${file%.pid}.done" "$$" || exit 1
    ! kill -0 "$child" 2>/dev/null || exit 1
  done
  [ "$found" = 1 ]
)
