#!/usr/bin/env bash
# Synthetic zombie-only groups, with no editor, device or real group signalling.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release.sh"
. "$here/lib/quest-release-timebox.sh"
qr_test_no_gtimeout

qr_config() { QR_LOGS="$tmp/$scenario"; }
qr_prepare() {
  if [ "$scenario" = timebox ]; then
    QR_TIMEBOX_KILL_AFTER=0 qr_timebox 5 true
  fi
}

# A partial listing can show a zombie but not establish absence of live
# members. The synthetic kernel still sees that group after KILL.
ps() {
  local zombie=999999
  if [ -s "$QR_LOGS/escalated" ]; then read -r zombie < "$QR_LOGS/escalated"; fi
  printf '%s Z\n' "$zombie"
  [ "${PROBE_FAIL:-0}" = 0 ]
}
fake_zombie_group() {
  local step_group
  read -r step_group < "$QR_LOGS/run.lock/group" || return 1
  if [ "$scenario" = timebox ]; then [ "$1" != "$step_group" ]; else [ "$1" = "$step_group" ]; fi
}
kill() {
  local pgid="${3:-}" probes
  pgid="${pgid#-}"
  case "$*" in
    '-0 -- -'*)
      fake_zombie_group "$pgid" || return 1
      if [ -s "$QR_LOGS/escalated" ]; then
        read -r probes < "$QR_LOGS/probes" || exit 98
        # A backstop so an unbounded loop fails instead of hanging the suite.
        [ "$probes" -lt 60 ] || exit 99
        printf '%s\n' "$((probes + 1))" > "$QR_LOGS/probes"
      fi ;;
    '-TERM -- -'*|'-CONT -- -'*) : ;;
    '-KILL -- -'*)
      fake_zombie_group "$pgid" || exit 98
      [ -s "$QR_LOGS/probes" ] || printf '0\n' > "$QR_LOGS/probes"
      printf '%s\n' "$pgid" > "$QR_LOGS/escalated" ;;
    *) builtin kill "$@" ;;
  esac
}

if [ "${1:-}" = owner ]; then
  tmp="$2"; scenario="$3"; PROBE_FAIL=1
  if [ "$scenario" = cancel ]; then
    # Inject owner cancellation at wait, without sending signals to the fake group.
    wait() { qr_cancel prepare TERM; }
  fi
  qr_main prepare
  exit $?
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
for scenario in step cancel timebox; do
  bash "$0" owner "$tmp" "$scenario" > "$tmp/$scenario.out" 2>&1
  rc=$?
  QR_LOGS="$tmp/$scenario"
  if [ "$scenario" = timebox ]; then
    pgid=''; read -r pgid < "$QR_LOGS/escalated" || true
    records=("$QR_LOGS/run.lock"/step.*/worker.*/group."$pgid")
  else
    records=("$QR_LOGS/run.lock/group")
  fi
  if [ "$rc" = 1 ] && [ -e "${records[0]}" ] &&
      grep -q 'cleanup failed.*process group' "$tmp/$scenario.out" &&
      grep -qx 'rc=1' "$QR_LOGS/last-result" && grep -qx 'verdict=1' "$QR_LOGS/last-result" &&
      ! ( PROBE_FAIL=1 qr_lock_acquire ); then
    echo "ok   $scenario: unconfirmed group exit fails cleanup and preserves the lock"
  else
    echo "FAIL $scenario: expected bounded cleanup failure with a retained lock (rc=$rc)"
    cat "$tmp/$scenario.out"
    fails=$((fails + 1))
  fi
  if ( qr_lock_acquire && qr_lock_release ) && [ ! -e "$QR_LOGS/run.lock" ]; then
    echo "ok   $scenario: a successful listing of zombie-only groups allows reclaim"
  else
    echo "FAIL $scenario: confirmed exit did not allow reclaim"
    fails=$((fails + 1))
  fi
done
[ "$fails" = 0 ]
