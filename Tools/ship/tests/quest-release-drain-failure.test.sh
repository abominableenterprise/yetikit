#!/usr/bin/env bash
# Synthetic unconfirmed groups, with no editor, device or real group signalling.
export LC_ALL=C
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

qr_select_device() { QUEST_SERIAL=fixture-active; }
adb() { echo "$*" >> "$QR_LOGS/adb-calls"; return 1; }
qr_device_locked() { : > "$QR_LOGS/device-lock-attempt"; "$@"; }
qr_perf() {
  local QR_PERF_RUN_ROOT="$QR_RUN_DIR" QR_PERF_CURSOR
  QR_PERF_CURSOR="$(qr_lock_dir)/perf-device"
  qr_perf_note_device || return 1
  case "$scenario" in
    perf-pending)
      local QUEST_SERIAL marker
      for QUEST_SERIAL in fixture-earlier fixture-active fixture-unpublished; do
        marker="$(qr_perf_marker)" || return 1
        mkdir -p "${marker%/*}" || return 1
        [ "$QUEST_SERIAL" != fixture-unpublished ] || marker="$marker.tmp"
        printf '%s\n%s\n' "$QUEST_SERIAL" "$QR_RUN_DIR" > "$marker" || return 1
      done ;;
    perf-manual)
      local marker="$(printf '%s' "$QUEST_SERIAL" | qr_sha256).manual"
      qr_perf_manual_note || return 1 ;;
  esac
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
  local pgid="${3:-}" probes escalations=0
  pgid="${pgid#-}"
  case "$*" in
    '-0 -- -'*)
      fake_zombie_group "$pgid" || return 1
      if [ -s "$QR_LOGS/escalated" ]; then
        read -r probes < "$QR_LOGS/probes" || exit 98
        # Bound each post-escalation poll loop even if it never signals again.
        [ "$probes" -lt 60 ] || exit 99
        printf '%s\n' "$((probes + 1))" > "$QR_LOGS/probes"
      fi ;;
    '-TERM -- -'*|'-CONT -- -'*) : ;;
    '-KILL -- -'*)
      fake_zombie_group "$pgid" || exit 98
      if [ -s "$QR_LOGS/escalations" ]; then read -r escalations < "$QR_LOGS/escalations"; fi
      # The owner can retry the timebox's drain once, but neither drain may loop on KILL.
      [ "$escalations" -lt 2 ] || exit 99
      printf '%s\n' "$((escalations + 1))" > "$QR_LOGS/escalations"
      printf '0\n' > "$QR_LOGS/probes"
      printf '%s\n' "$pgid" > "$QR_LOGS/escalated" ;;
    *) builtin kill "$@" ;;
  esac
}

if [ "${1:-}" = owner ]; then
  tmp="$2"; scenario="$3"; PROBE_FAIL=1
  case "$scenario" in
    cancel)
      # Inject owner cancellation at wait, without sending signals to the fake group.
      wait() { qr_cancel prepare TERM; } ;;
    perf-*)
      wait() {
        builtin wait "$@" || exit 97 # The fake worker has published its recovery state.
        qr_cancel perf TERM
      }
      if [ "$scenario" = perf-manual ]; then qr_main perf stop; else qr_main perf --seconds 1 --warmup 0; fi
      exit $? ;;
  esac
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
for scenario in perf-pending perf-manual perf-empty; do
  bash "$0" owner "$tmp" "$scenario" > "$tmp/$scenario.out" 2>&1
  rc=$?
  QR_LOGS="$tmp/$scenario"
  out="$tmp/$scenario.out"
  run=''; read -r run < "$QR_LOGS/run.lock/run_dir" || true
  marker_ok=0
  case "$scenario" in
    perf-pending)
      if [ "$(grep -l '^fixture-\(earlier\|active\)$' "$run"/perf-pending/* | wc -l)" -eq 2 ] &&
          grep -Fq 'adb -s fixture-earlier shell am broadcast -a com.oculus.vrpowermanager.automation_disable' "$out" &&
          grep -Fq 'adb -s fixture-active shell am broadcast -a com.oculus.vrpowermanager.automation_disable' "$out" &&
          ! grep -Fq 'fixture-unpublished' "$out"; then marker_ok=1; fi ;;
    perf-manual)
      if grep -qx 'fixture-active' "$QR_LOGS/run.lock"/perf-manual/*.manual &&
          grep -Fq 'perf stop for fixture-active' "$out"; then marker_ok=1; fi ;;
    perf-empty)
      if ! grep -q 'WARN:' "$out"; then marker_ok=1; fi ;;
  esac
  if [ "$rc" = 1 ] && [ -f "$QR_LOGS/run.lock/group" ] &&
      grep -q 'cleanup failed.*process group' "$out" &&
      grep -qx 'cmd=perf' "$QR_LOGS/last-result" && grep -qx 'rc=1' "$QR_LOGS/last-result" &&
      grep -qx 'verdict=1' "$QR_LOGS/last-result" && [ "$marker_ok" = 1 ] &&
      [ ! -e "$QR_LOGS/adb-calls" ] && [ ! -e "$QR_LOGS/device-lock-attempt" ]; then
    echo "ok   $scenario: unconfirmed cancellation fails and warns only for pending recovery, without retrying"
  else
    echo "FAIL $scenario: expected retained lock, failure verdict and pending-only warnings without recovery (rc=$rc)"
    cat "$out"
    fails=$((fails + 1))
  fi
done

# Model independent registered siblings and an unreachable descendant of the
# first group. Give each TERM a synthetic expired grace period; the real
# post-KILL poll runs against fake liveness and must remain bounded.
if (
  root="$tmp/workers"; signals="$tmp/signals"; : > "$signals"
  qr_own_group_alive() {
    case "$1" in
      8101|8102) return 0 ;;
      8103) ! grep -qx -- '-KILL 8103' "$signals" ;;
      *) return 1 ;;
    esac
  }
  kill() {
    printf '%s %s\n' "$1" "${3#-}" >> "$signals"
    if [ "$1" = -TERM ]; then SECONDS=$((SECONDS + 2)); fi
  }
  mkdir -p "$root/worker.1/group.8101/worker.child/group.8104" \
    "$root/worker.2/group.8102" "$root/worker.3/group.8103"
  rc=0; qr_workers_drain "$root" || rc=$?
  [ "$rc" = 1 ] && [ -d "$root/worker.1/group.8101/worker.child/group.8104" ] &&
    [ -d "$root/worker.2/group.8102" ] && [ ! -e "$root/worker.3" ] &&
    [ "$(grep -E '^-(TERM|KILL) ' "$signals")" = "$(printf '%s\n' \
      '-TERM 8101' '-KILL 8101' '-TERM 8102' '-KILL 8102' '-TERM 8103' '-KILL 8103')" ]
) > "$tmp/workers.out" 2>&1; then
  echo 'ok   worker drain visits all independent siblings and retains unconfirmed records'
else
  echo 'FAIL worker drain should continue after an unconfirmed sibling and return aggregate failure'
  cat "$tmp/workers.out" "$tmp/signals"
  fails=$((fails + 1))
fi
[ "$fails" = 0 ]
