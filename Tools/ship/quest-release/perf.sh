# shellcheck shell=bash
# Scripted compositor capture. Keep all device mutations inside the headset lock.
qr_perf_sleep() { sleep "$1"; }
qr_perf_now() { date +%s; }
qr_perf_pid_sleep() { sleep 0.2; }

qr_perf_report() {
  local scene version_name version_code sha rc
  scene="$(jq -r 'index("-scene") as $i | if $i == null then "default" else .[$i+1] // "default" end' <<< "$QR_LAUNCH_ARGS")"
  version_name="$(printf '%s\n' "$perf_package" | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | head -n1)"
  version_code="$(printf '%s\n' "$perf_package" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n1)"
  sha="${QR_PERF_SHA:-unavailable}"
  jq -Rs --arg model "${perf_model:-unavailable}" --arg mode "$perf_mode" \
    --argjson seconds "$QR_PERF_SECONDS" --argjson warmup "$QR_PERF_WARMUP" \
    --argjson maxStale "$QR_PERF_MAX_STALE" --argjson maxApp "$QR_PERF_MAX_APP" \
    --arg thermalStart "$perf_thermal_start" --arg thermalEnd "$perf_thermal_end" \
    --arg scene "$scene" --arg sha "$sha" --arg versionName "${version_name:-unavailable}" \
    --arg versionCode "${version_code:-unavailable}" --arg error "$perf_error" \
    --arg pid "${perf_pid:-}" \
    --argjson windowStart "${perf_start:-null}" --argjson windowEnd "${perf_end:-null}" \
    -f "$QR_DIR/quest-release/perf-stats.jq" "$QR_RUN_DIR/perf-logcat.txt" \
    > "$QR_RUN_DIR/perf-summary.json" || return 3
  jq -r '
    "Quest performance: \(.overall)",
    "device model: \(.model) (\(.mode))", "CPU/GPU levels: \(.levels)",
    "thermal start/end: \(.thermalStart) / \(.thermalEnd)",
    "APK versionName/versionCode: \(.versionName) / \(.versionCode)", "APK sha256: \(.apkSha256)",
    "scene: \(.scene)", "window: \(.seconds)s; warm-up excluded: \(.warmupSeconds)s; samples: \(.samples)",
    "stale frames: \(.stalePercent)% <= \(.gates.stale.limit)%: \(.gates.stale.verdict)",
    "App p95 (per-second samples): \(.p95AppMs) ms <= \(.gates.app.limit) ms: \(.gates.app.verdict)",
    "average fps (report only): \(.averageFps)", "worst App: \(.worstAppMs) ms",
    "longest consecutive stale seconds: \(.longestStaleStreak)",
    "CPU/GPU frame time mean: \(.cpuMs) / \(.gpuMs) ms",
    (if .message != "" then .message else empty end)
  ' "$QR_RUN_DIR/perf-summary.json" > "$QR_RUN_DIR/perf-summary.txt" || return 3
  qr_set perf "$(cat "$QR_RUN_DIR/perf-summary.txt")"
  case "$(jq -r .overall "$QR_RUN_DIR/perf-summary.json")" in
    PASS|REPORT) rc=0 ;; FAIL) rc=1 ;; *) rc=3 ;;
  esac
  qr_set perf_result "$rc"
  perf_reported=1
  return "$rc"
}

# Optional diagnostic: unsupported thermalservice must not make capture fail.
qr_perf_thermal() {
  local out
  out="$(qr_adb shell dumpsys thermalservice 2>/dev/null)" || out=''
  out="$(printf '%s\n' "$out" | tr -d '\r' | grep -E 'Thermal Status:|mStatus=' | head -n1)"
  printf '%s\n' "${out:-unavailable}"
}

qr_perf_restore() {
  [ "$perf_prox" = 1 ] || return 0
  # Clear only after success: EXIT retries a failed explicit restoration.
  if QR_TIMEBOX_KILL_AFTER=1 qr_timebox "${QR_PERF_RESTORE_WAIT:-10}" adb -s "$QUEST_SERIAL" shell am broadcast -a com.oculus.vrpowermanager.automation_disable >> "$QR_RUN_DIR/perf-prox.log" 2>&1; then
    perf_prox=0
    # EXIT retries also own cleanup, but must not clear another device's marker.
    [ "${perf_reported:-0}" != 1 ] || qr_perf_clear_marker
  else
    local warning="WARN: proximity sensor may still be disabled; run: adb -s $QUEST_SERIAL shell am broadcast -a com.oculus.vrpowermanager.automation_disable"
    perf_error="${perf_error:+$perf_error; }adb proximity restoration failed or timed out (see perf-prox.log); $warning"
    qr_log "$warning"
    return 3
  fi
}

# Keep recovery owned until a complete summary exists, including on EXIT retry.
qr_perf_clear_marker() {
  local marker="$QR_PERF_RUN_ROOT/perf-active"
  if [ "$(head -n1 "$marker" 2>/dev/null)" = "$QUEST_SERIAL" ] && [ "$(tail -n1 "$marker" 2>/dev/null)" = "$QR_RUN_DIR" ]; then rm -f "$marker"; fi
}

# Fail closed if the launched process disappears/restarts or loses foreground.
# Poll through the window, not just at its endpoints; logcat is also PID-bound.
qr_perf_identity() {
  local pid activity
  pid="$(qr_launch_pid)" || return 3
  [ -n "$pid" ] && [ "$pid" = "$perf_pid" ] || return 3
  activity="$(qr_adb shell dumpsys activity activities 2>/dev/null)" || return 3
  printf '%s\n' "$activity" | awk -v package="$QR_PKG" '
    /mResumedActivity:|topResumedActivity=/ {
      for (i = 1; i <= NF; i++) if (index($i, package "/") == 1) found = 1
    }
    END {exit !found}'
}

qr_perf_capture() {
  local deadline clock remaining
  # am start may return before a cold-started process exists. Keep launch's
  # behaviour unchanged: only perf polls, and warm-up begins after discovery.
  deadline=$(( $(qr_perf_now) + QR_PERF_PID_WAIT ))
  while :; do
    remaining=$((deadline - $(qr_perf_now)))
    if [ "$remaining" -le 0 ]; then
      perf_error="target app has no live PID after ${QR_PERF_PID_WAIT}s"; return
    fi
    perf_pid="$(QR_TIMEBOX_KILL_AFTER=1 qr_launch_pid qr_timebox "$remaining" adb -s "$QUEST_SERIAL")" \
      || { perf_error='initial app PID probe failed or timed out'; return; }
    if [ "$(qr_perf_now)" -gt "$deadline" ]; then
      perf_error="target app PID probe exceeded ${QR_PERF_PID_WAIT}s deadline"; return
    fi
    if [ -n "$perf_pid" ]; then
      [[ "$perf_pid" =~ ^[0-9]+$ ]] || { perf_error='target app has multiple live PIDs'; return; }
      break
    fi
    if [ "$(qr_perf_now)" -ge "$deadline" ]; then
      perf_error="target app has no live PID after ${QR_PERF_PID_WAIT}s"; return
    fi
    qr_perf_pid_sleep
  done
  qr_perf_sleep "$QR_PERF_WARMUP"
  qr_perf_identity || { perf_error='target app identity/foreground lost during warm-up'; return; }
  perf_thermal_start="$(qr_perf_thermal)"
  # Clearing AFTER warm-up makes buffered warm-up samples ineligible.
  if ! qr_adb logcat -c; then
    perf_error='adb logcat -c failed'; return
  fi
  # Use the device's epoch for logcat boundaries (host clocks may differ).
  # Anchor elapsed time BEFORE the clock query so its transport cost cannot
  # extend the requested window. Slow transports may fail coverage, never pass
  # by diluting hitches with healthy samples collected after the deadline.
  deadline=$(( $(qr_perf_now) + QR_PERF_SECONDS ))
  clock="$(qr_adb shell date +%s)" || { perf_error='adb capture clock query failed'; return; }
  clock="${clock//$'\r'/}"
  [[ "$clock" =~ ^[0-9]+$ ]] || { perf_error='invalid adb capture clock'; return; }
  perf_start="$clock"; perf_end=$((perf_start + QR_PERF_SECONDS))
  while [ "$(qr_perf_now)" -lt "$deadline" ]; do
    qr_perf_sleep 1
    if ! qr_perf_identity; then
      perf_error='target app identity/foreground lost during capture'; break
    fi
  done
  qr_adb logcat -d -v epoch --pid="$perf_pid" -s VrApi > "$QR_RUN_DIR/perf-logcat.txt" 2> "$QR_RUN_DIR/perf-adb.err" \
    || perf_error='adb logcat capture failed'
  perf_thermal_end="$(qr_perf_thermal)"
}

qr_perf_locked() (
  local perf_prox=0 perf_error='' perf_model='' perf_package='' perf_mode=report perf_pid='' perf_reported=0
  local perf_start=null perf_end=null
  local perf_thermal_start=unavailable perf_thermal_end=unavailable
  : > "$QR_RUN_DIR/perf-logcat.txt"
  # This subshell's cleanup leaves qr_device_locked's lock/cancel traps intact.
  trap 'qr_perf_restore' EXIT
  trap 'perf_error="capture cancelled"; qr_perf_restore; qr_perf_report; [ "$perf_prox" != 0 ] || qr_perf_clear_marker; exit 3' HUP INT TERM
  if ! ( qr_await_device ); then
    perf_error='device check/wait failed'
  else
    perf_model="$(qr_adb shell getprop ro.product.model 2>/dev/null)" || perf_error='adb model query failed'
    perf_package="$(qr_adb shell dumpsys package "$QR_PKG" 2>/dev/null)" || perf_error='adb package query failed'
    perf_model="${perf_model//$'\r'/}"
    perf_package="${perf_package//$'\r'/}"
    perf_mode="$(qr_config_get '.quest.perf.devices // {}' | jq -r --arg model "$perf_model" '.[$model] // "report"')"
    # Arm cleanup BEFORE attempting the broadcast: transport can fail after delivery.
    printf '%s\n%s\n' "$QUEST_SERIAL" "$QR_RUN_DIR" > "$QR_PERF_RUN_ROOT/perf-active.tmp" \
      && mv -f "$QR_PERF_RUN_ROOT/perf-active.tmp" "$QR_PERF_RUN_ROOT/perf-active" || exit 3
    perf_prox=1
    if [ -n "$perf_error" ]; then
      : # Preserve metadata transport failure; report fields as unavailable.
    elif ! qr_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close > "$QR_RUN_DIR/perf-prox.log" 2>&1; then
      perf_error='adb proximity override failed'
    elif ! ( qr_start_activity ) > "$QR_RUN_DIR/perf-am.log" 2>&1; then
      perf_error='am start failed (perf-am.log)'
    elif grep -Eq '^[[:space:]]*(Error([[:space:]:]|$)|Exception([[:space:]:]|$)|[[:alnum:]_.$]+Exception:)' "$QR_RUN_DIR/perf-am.log"; then
      perf_error='am start reported an error (perf-am.log)'
    else
      qr_perf_capture
    fi
  fi
  qr_perf_restore || true
  local rc=0
  qr_perf_report || rc=$?
  [ "$perf_prox" != 0 ] || qr_perf_clear_marker
  exit "$rc"
)

# The owner runs this AFTER draining the worker group. A slow EXIT trap may be
# killed by the existing bounded drain; the durable marker keeps cleanup owned.
qr_perf_cancel() {
  local marker="$QR_RUN_DIR/perf-active" serial dir
  [ -f "$marker" ] || return 0
  serial="$(head -n1 "$marker")"; dir="$(tail -n1 "$marker")"
  ( local QR_PERF_RUN_ROOT="$QR_RUN_DIR"
    QUEST_SERIAL="$serial"; QR_RUN_DIR="$dir"
    local perf_prox=1 perf_error='capture cancelled' perf_model='' perf_package='' perf_mode=report
    local perf_thermal_start=unavailable perf_thermal_end=unavailable
    qr_perf_restore || true
    qr_perf_report || true
    # Best effort only: even failed/timed-out restoration cannot retain run
    # ownership. The summary carries the manual recovery command instead.
    rm -f "$marker"
  )
  qr_set perf 'INFRA: capture cancelled (see per-device performance summary)'
  qr_set perf_result 3
}

qr_perf_device() {
  local rc=0
  qr_set perf 'INFRA: performance capture did not complete (device lock/setup or cancel)'
  qr_set perf_result 3
  rm -f "$QR_RUN_DIR/perf-summary.json" "$QR_RUN_DIR/perf-summary.txt"
  qr_device_locked qr_perf_locked || rc=$?
  # A refused device lock still needs its own fresh machine-readable outcome.
  if [ ! -s "$QR_RUN_DIR/perf-summary.json" ]; then
    local perf_error='device lock/setup failed' perf_model='' perf_package='' perf_mode=report
    local perf_thermal_start=unavailable perf_thermal_end=unavailable
    : > "$QR_RUN_DIR/perf-logcat.txt"
    qr_perf_report || true
  fi
  # Device-lock failures use infrastructure status, not a performance gate fail.
  [ "$(qr_get perf_result 3)" != 3 ] || rc=3
  return "$rc"
}

qr_perf() {
  local serial path run="$QR_RUN_DIR" total=0 rc previous
  while [ $# -gt 0 ]; do
    case "$1" in
      --seconds|--warmup)
        [ $# -ge 2 ] || qr_die "perf: $1 needs seconds"
        case "$2" in ''|*[!0-9]*) qr_die 'perf: seconds must be integers' ;; esac
        if [ "$1" = --seconds ]; then QR_PERF_SECONDS="$2"; else QR_PERF_WARMUP="$2"; fi
        shift ;;
      *) qr_die 'usage: perf [--seconds N] [--warmup S] (manual windows not yet supported)' ;;
    esac
    shift
  done
  QR_PERF_PID_WAIT="${QR_PERF_PID_WAIT:-20}"
  QR_PERF_RESTORE_WAIT="${QR_PERF_RESTORE_WAIT:-10}"
  qr_positive_seconds QR_PERF_PID_WAIT "$QR_PERF_PID_WAIT" || return 1
  qr_positive_seconds QR_PERF_RESTORE_WAIT "$QR_PERF_RESTORE_WAIT" || return 1
  qr_positive_seconds 'perf seconds' "$QR_PERF_SECONDS" || return 1
  case "$QR_PERF_WARMUP" in 0) ;; *) qr_positive_seconds 'perf warmup' "$QR_PERF_WARMUP" || return 1 ;; esac
  QR_PERF_RUN_ROOT="$QR_RUN_DIR"
  QR_PERF_SHA="$(qr_get apk_sha256 unavailable)"
  qr_set device_results ''; qr_set multi_command ''; qr_set overall ''
  if [ "${#QR_SERIALS[@]}" = 1 ]; then qr_perf_device; return $?; fi
  qr_set perf 'per-device performance captures (see below)'
  qr_set multi_command perf; qr_set multi_result 3
  for serial in "${QR_SERIALS[@]}"; do
    path="$(qr_serial_path "$serial")"
    mkdir -p "$run/devices/$path" || return 3
    rc=0
    ( QUEST_SERIAL="$serial"; QR_RUN_DIR="$run/devices/$path"; qr_perf_device ) || rc=$?
    total="$(qr_worst "$total" "$rc")"
    previous="$(qr_get device_results '')"
    qr_set device_results "${previous:+$previous$'\n'}perf[$serial]: $(QR_RUN_DIR="$run/devices/$path" qr_get perf)"
  done
  qr_set multi_result "$total"; qr_set perf_result "$total"
  qr_set overall "perf exit $total (gate failure > infrastructure > success)"
  return "$total"
}
