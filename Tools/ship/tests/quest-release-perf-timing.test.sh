#!/usr/bin/env bash
# Focused capture timing against synthetic host/device clocks and logcat.
set -eu
QR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$QR_DIR/quest-release/perf.sh"
QR_RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$QR_RUN_DIR"' EXIT
QR_PERF_SECONDS=20 QR_PERF_WARMUP=0 QR_PERF_PID_WAIT=3
QR_PERF_MAX_STALE=1 QR_PERF_MAX_APP=20 QR_LAUNCH_ARGS='[]' QUEST_SERIAL=synthetic

host_ms() { local ms; read -r ms < "$QR_RUN_DIR/clock"; printf '%s\n' "$ms"; }
advance() { echo "$(( $(host_ms) + $1 ))" > "$QR_RUN_DIR/clock"; }
# Main reads integer host seconds with date; the fixed code reads monotonic ms.
date() { [ "$*" = '+%s' ] && echo "$(( $(host_ms) / 1000 ))"; }
perl() { host_ms; }
qr_timebox() { shift; "$@"; }
qr_launch_pid() { echo 4242; }
qr_perf_thermal() { echo unavailable; }
qr_set() { :; }
qr_perf_sleep() { advance "$(LC_ALL=C awk -v seconds="$1" 'BEGIN {printf "%.0f", seconds * 1000}')"; }
qr_perf_identity() {
  local elapsed=$(( $(host_ms) - 950 ))
  # The first in-window probe stalls, once; the warm-up check stays fast.
  case "$case_name:$elapsed" in
    slow-clock:11000) advance 25000 ;;
    fractional:1100) advance 300 ;;
  esac
  return 0
}
qr_adb() { adb -s "$QUEST_SERIAL" "$@"; }
adb() {
  shift 2
  local now i stale sample_ms count=20
  case "$*" in
    'logcat -c') : ;;
    'shell date +%s'|'shell date +%s.%N')
      case "$case_name" in slow-clock) advance 10000 ;; fractional) advance 100 ;; esac
      now=$((1700000000000 + $(host_ms)))
      case "$3" in
        '+%s') echo "$((now / 1000))" ;;
        '+%s.%N') printf '%s.%03d000000\r\n' "$((now / 1000))" "$((now % 1000))" ;;
      esac ;;
    'logcat -d '*)
      # Only emit telemetry that would have accrued by dump time. Continue
      # beyond the requested window when the clock and identity probes stall.
      now="$(host_ms)"
      [ "$case_name" != slow-clock ] || count=40
      # This late/slightly shifted cadence leaves one real row in the final
      # fractional second. Neighboring out-of-window rows must not dilute it.
      if [ "$case_name" = fractional ]; then
        printf '1700000001.049999 4242 4242 I VrApi: FPS=72,Stale=0,App=99ms\n'
        if [ "$now" -ge 21050 ]; then
          printf '1700000021.050000 4242 4242 I VrApi: FPS=72,Stale=0,App=99ms\n'
        fi
      fi
      for ((i=1; i<=count; i++)); do
        case "$case_name:$i" in missing-interior:10|missing-boundary:20) continue ;; esac
        stale=0
        case "$case_name:$i" in
          slow-clock:2|slow-clock:3|full:10|fractional:20) stale=40 ;;
        esac
        # Model a phase change for the fractional case without changing the
        # one-second spacing; its last hitch falls just inside the end.
        case "$case_name" in
          fractional) sample_ms=$((i * 1000 + 1040)) ;;
          slow-clock) sample_ms=$((i * 1000 + 900)) ;;
          *) sample_ms=$((i * 1000 - 25)) ;;
        esac
        [ "$sample_ms" -le "$now" ] || break
        printf '%s.%03d000 4242 4242 I VrApi: FPS=72,Stale=%d,App=5ms\n' \
          "$((1700000000 + sample_ms / 1000))" "$((sample_ms % 1000))" "$stale"
      done ;;
    *) return 99 ;;
  esac
}

fails=0
run_case() {
  local case_name="$1" assertion="$2" rc=0
  local perf_error='' perf_pid='' perf_start=null perf_end=null perf_mode=gate
  local perf_model='' perf_package='' perf_thermal_start=unavailable perf_thermal_end=unavailable perf_reported=0
  echo 950 > "$QR_RUN_DIR/clock"
  : > "$QR_RUN_DIR/perf-logcat.txt"
  qr_perf_capture
  qr_perf_report || rc=$?
  if jq -e --argjson rc "$rc" --argjson elapsed "$(( $(host_ms) - 950 ))" "$assertion" \
      "$QR_RUN_DIR/perf-summary.json" >/dev/null; then
    printf 'ok   %s\n' "$case_name"
  else
    printf 'FAIL %s: rc=%s elapsed=%sms\n' "$case_name" "$rc" "$(( $(host_ms) - 950 ))"
    jq '{overall, samples, stalePercent, message}' "$QR_RUN_DIR/perf-summary.json"
    fails=$((fails + 1))
  fi
}
run_case full '$rc == 1 and .overall == "FAIL" and .samples == 20'
run_case missing-interior '$rc == 3 and .overall == "INFRA" and .samples == 19 and (.message | contains("coverage"))'
run_case missing-boundary '$rc == 0 and .overall == "PASS" and .samples == 19'
run_case fractional '$rc == 1 and .overall == "FAIL" and .samples == 20 and .worstAppMs == 5 and .gates.stale.verdict == "FAIL" and $elapsed == 20100'
run_case slow-clock '$rc == 3 and .overall == "INFRA" and (.message | contains("clock"))'
[ "$fails" = 0 ]
