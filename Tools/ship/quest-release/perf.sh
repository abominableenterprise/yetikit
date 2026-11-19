# shellcheck shell=bash
# Scripted compositor capture. Keep all device mutations inside the headset lock.
qr_perf_sleep() { sleep "$1"; }
# Monotonic milliseconds; stock macOS Bash has neither EPOCHREALTIME nor GNU date.
qr_perf_now() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e '
    my $now = clock_gettime(CLOCK_MONOTONIC);
    defined $now or exit 1;
    printf "%.0f\n", 1000 * $now;'
}
qr_perf_pid_sleep() { sleep 0.2; }

qr_perf_report() {
  local scene version_name version_code sha rc summary
  scene="$(jq -r '
    def scene: index("-scene") as $i | if $i == null then null else .[$i+1] end;
    scene // ([range(0; length) as $i | select(.[$i:$i+2] == ["--es", "unity"]) |
      .[$i+2] // empty |
      [match("\"[^\"]*\"|[^\\s\"]+"; "g").string | sub("^\"|\"$"; ""; "g")] |
      scene // empty] | last) // "default"
  ' <<< "$QR_LAUNCH_ARGS")"
  version_name="$(printf '%s\n' "$perf_package" | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | head -n1)"
  version_code="$(printf '%s\n' "$perf_package" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n1)"
  sha="${QR_PERF_SHA:-unavailable}"
  jq -Rs --arg model "${perf_model:-unavailable}" --arg mode "$perf_mode" \
    --argjson seconds "$QR_PERF_SECONDS" --argjson warmup "$QR_PERF_WARMUP" \
    --argjson maxStale "$QR_PERF_MAX_STALE" --argjson maxApp "$QR_PERF_MAX_APP" \
    --arg thermalStart "$perf_thermal_start" --arg thermalEnd "$perf_thermal_end" \
    --arg scene "${perf_scene:-$scene}" --arg sha "$sha" --arg versionName "${version_name:-unavailable}" \
    --arg versionCode "${version_code:-unavailable}" --arg error "$perf_error" \
    --arg pid "${perf_pid:-}" \
    --argjson windowStart "${perf_start:-null}" --argjson windowEnd "${perf_end:-null}" \
    -f "$QR_DIR/quest-release/perf-stats.jq" "$QR_RUN_DIR/perf-logcat.txt" \
    > "$QR_RUN_DIR/perf-summary.json" || return 3
  jq -r '
    # Text formatting only; JSON and gate inputs retain their original precision.
    def fixed($digits):
      if type != "number" then . else
        (pow(10; $digits)) as $scale |
        ((. * $scale | round) / $scale | tostring | split(".")) as $parts |
        $parts[0] + "." + ((($parts[1] // "") + "000000")[0:$digits])
      end;
    def sensor($index): split("/") | .[$index] // "unavailable";
    def nonzero: (try (sub("C$"; "") | tonumber) catch 0) != 0;
    "Quest performance: \(.overall)",
    "device model: \(.model) (\(.mode))", "CPU/GPU levels: \(.levels)",
    "thermal start/end: \(.thermalStart | sensor(0)) / \(.thermalEnd | sensor(0))" +
      (if any([.thermalStart, .thermalEnd][]; sensor(1) | nonzero) then
        "; second sensor: \(.thermalStart | sensor(1)) / \(.thermalEnd | sensor(1))" else "" end),
    "APK versionName/versionCode: \(.versionName) / \(.versionCode)", "APK sha256: \(.apkSha256)",
    "scene: \(.scene)", "window: \(.seconds)s; warm-up excluded: \(.warmupSeconds)s; samples: \(.samples)",
    "stale frames: \(.stalePercent)% <= \(.gates.stale.limit)%: \(.gates.stale.verdict)",
    "App p95 (per-second samples): \(.p95AppMs) ms <= \(.gates.app.limit) ms: \(.gates.app.verdict)",
    "average fps (report only): \(.averageFps | fixed(1))", "worst App: \(.worstAppMs | fixed(2)) ms",
    "longest consecutive stale seconds: \(.longestStaleStreak)",
    ((.combinedMs | type == "number") as $hasCombined |
      (if .cpuMs != "unavailable" or .gpuMs != "unavailable" or ($hasCombined | not) then
        "CPU/GPU frame time mean: \(.cpuMs | fixed(2)) / \(.gpuMs | fixed(2)) ms"
      else empty end),
      (if $hasCombined and (.cpuMs == "unavailable" or .gpuMs == "unavailable") then
        "CPU&GPU frame time mean (combined): \(.combinedMs | fixed(2)) ms"
      else empty end)),
    (if (.cpuUtilization | type) == "number" or (.gpuUtilization | type) == "number" then
      "CPU/GPU utilisation mean (report only): \(.cpuUtilization | fixed(2)) / \(.gpuUtilization | fixed(2))"
    else empty end),
    (if .message != "" then .message else empty end)
  ' "$QR_RUN_DIR/perf-summary.json" > "$QR_RUN_DIR/perf-summary.txt" || return 3
  summary="$(cat "$QR_RUN_DIR/perf-summary.txt")" || return 3
  qr_set perf "$summary" || return 3
  case "$(jq -r .overall "$QR_RUN_DIR/perf-summary.json")" in
    PASS|REPORT) rc=0 ;; FAIL) rc=1 ;; *) rc=3 ;;
  esac
  qr_set perf_result "$rc" || return 3
  perf_reported=1
  return "$rc"
}

# Hash the captured installation, not a possibly unrelated local APK/state hash.
# Missing tools, split-only/ambiguous paths and transport failures are report-only.
qr_perf_apk_sha() {
  local path out
  path="$(QR_TIMEBOX_KILL_AFTER=1 qr_timebox 5 adb -s "$QUEST_SERIAL" shell pm path "$QR_PKG" 2>/dev/null)" || { echo unavailable; return; }
  path="${path//$'\r'/}"
  # Only accept a single base APK path; never interpolate device output into shell code.
  if [[ ! "$path" =~ ^package:/[a-zA-Z0-9_./=+~-]+/base\.apk$ ]]; then echo unavailable; return; fi
  out="$(QR_TIMEBOX_KILL_AFTER=1 qr_timebox 5 adb -s "$QUEST_SERIAL" shell sha256sum "${path#package:}" 2>/dev/null)" || { echo unavailable; return; }
  if [[ "$out" =~ ^([a-fA-F0-9]{64})[[:space:]] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" | tr 'A-F' 'a-f'
  else echo unavailable; fi
}

# Optional diagnostic: unsupported thermalservice must not make capture fail.
qr_perf_thermal() {
  local out
  [ "$#" != 0 ] || set -- qr_adb
  out="$("$@" shell dumpsys thermalservice 2>/dev/null)" || out=''
  out="$(printf '%s\n' "$out" | tr -d '\r' | grep -E 'Thermal Status:|mStatus=' | head -n1)"
  printf '%s\n' "${out:-unavailable}"
}

# Fail closed if the launched process disappears/restarts or loses foreground.
# Poll through the window, not just at its endpoints; logcat is also PID-bound.
qr_perf_identity() {
  local pid activity
  [ "$#" != 0 ] || set -- qr_adb
  pid="$(qr_launch_pid "$@")" || return 3
  [ -n "$pid" ] && [ "$pid" = "$perf_pid" ] || return 3
  activity="$("$@" shell dumpsys activity activities 2>/dev/null)" || return 3
  printf '%s\n' "$activity" | awk -v package="$QR_PKG" '
    /mResumedActivity:|topResumedActivity=/ {
      for (i = 1; i <= NF; i++) if (index($i, package "/") == 1) found = 1
    }
    END {exit !found}'
}

# Bracket the device epoch query on the host to reject transport-delayed edges.
qr_perf_clock() {
  local clock query_start
  query_start="$(qr_perf_now)" || { perf_error='host monotonic clock unavailable'; return 3; }
  clock="$(QR_TIMEBOX_KILL_AFTER=1 qr_timebox 0.5 adb -s "$QUEST_SERIAL" shell date +%s.%N)" \
    || { perf_error='adb capture clock query failed or timed out'; return 3; }
  perf_clock_host_ms="$(qr_perf_now)" || { perf_error='host monotonic clock unavailable'; return 3; }
  if [ "$((perf_clock_host_ms - query_start))" -ge 500 ]; then
    perf_error='adb capture clock query exceeded 500ms latency budget'; return 3
  fi
  clock="${clock//$'\r'/}"
  [[ "$clock" =~ ^(0|[1-9][0-9]{0,11})\.[0-9]{9}$ ]] || { perf_error='invalid adb capture clock'; return 3; }
  perf_clock="$clock"
}

qr_perf_metadata() {
  [ "$#" != 0 ] || set -- qr_adb
  perf_model="$("$@" shell getprop ro.product.model 2>/dev/null)" || perf_error='adb model query failed'
  perf_package="$("$@" shell dumpsys package "$QR_PKG" 2>/dev/null)" || perf_error='adb package query failed'
  perf_model="${perf_model//$'\r'/}"
  perf_package="${perf_package//$'\r'/}"
  QR_PERF_SHA="$(qr_perf_apk_sha)"
  perf_mode="$(qr_config_get '.quest.perf.devices // {}' | jq -r --arg model "$perf_model" '.[$model] // "report"')"
}

qr_perf_capture() {
  local deadline remaining now delay perf_clock perf_clock_host_ms
  local host_clock_error='host monotonic clock unavailable'
  # am start may return before a cold-started process exists. Keep launch's
  # behaviour unchanged: only perf polls, and warm-up begins after discovery.
  now="$(qr_perf_now)" || { perf_error="$host_clock_error"; return; }
  deadline=$((now + QR_PERF_PID_WAIT * 1000))
  while :; do
    remaining=$((deadline - now))
    if [ "$remaining" -le 0 ]; then
      perf_error="target app has no live PID after ${QR_PERF_PID_WAIT}s"; return
    fi
    printf -v delay '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
    perf_pid="$(QR_TIMEBOX_KILL_AFTER=1 qr_launch_pid qr_timebox "$delay" adb -s "$QUEST_SERIAL")" \
      || { perf_error='initial app PID probe failed or timed out'; return; }
    now="$(qr_perf_now)" || { perf_error="$host_clock_error"; return; }
    if [ "$now" -gt "$deadline" ]; then
      perf_error="target app PID probe exceeded ${QR_PERF_PID_WAIT}s deadline"; return
    fi
    if [ -n "$perf_pid" ]; then
      [[ "$perf_pid" =~ ^[0-9]+$ ]] || { perf_error='target app has multiple live PIDs'; return; }
      break
    fi
    if [ "$now" -lt "$deadline" ]; then
      qr_perf_pid_sleep
      now="$(qr_perf_now)" || { perf_error="$host_clock_error"; return; }
    fi
  done
  qr_perf_sleep "$QR_PERF_WARMUP"
  qr_perf_identity || { perf_error='target app identity/foreground lost during warm-up'; return; }
  perf_thermal_start="$(qr_perf_thermal)"
  # Clearing AFTER warm-up makes buffered warm-up samples ineligible.
  if ! qr_adb logcat -c; then
    perf_error='adb logcat -c failed'; return
  fi
  qr_perf_clock || return 0 # Report the clock error through perf_error.
  now="$perf_clock_host_ms"
  perf_start="$perf_clock"
  perf_end="$(( ${perf_start%.*} + QR_PERF_SECONDS )).${perf_start#*.}"
  # Wait through the latest possible end of the bracket. Only the exact
  # device interval enters the report, even if a probe delays the dump.
  deadline=$((now + QR_PERF_SECONDS * 1000))
  while [ "$now" -lt "$deadline" ]; do
    remaining=$((deadline - now))
    delay=1
    if [ "$remaining" -lt 1000 ]; then printf -v delay '0.%03d' "$remaining"; fi
    qr_perf_sleep "$delay"
    if ! qr_perf_identity; then
      perf_error='target app identity/foreground lost during capture'; break
    fi
    now="$(qr_perf_now)" || { perf_error="$host_clock_error"; return; }
  done
  qr_adb logcat -d -v epoch -v usec --pid="$perf_pid" -s VrApi > "$QR_RUN_DIR/perf-logcat.txt" 2> "$QR_RUN_DIR/perf-adb.err" \
    || perf_error='adb logcat capture failed'
  perf_thermal_end="$(qr_perf_thermal)"
}

qr_perf_locked() (
  local perf_prox=0 perf_error='' perf_model='' perf_package='' perf_mode=report perf_pid='' perf_reported=0
  local perf_start=null perf_end=null
  local perf_thermal_start=unavailable perf_thermal_end=unavailable
  : > "$QR_RUN_DIR/perf-logcat.txt"
  # This subshell's cleanup leaves qr_device_locked's lock/cancel traps intact.
  local marker
  marker="$(qr_perf_marker)" || exit 3
  trap 'qr_perf_restore' EXIT
  trap 'exit 3' HUP INT TERM
  if [ -f "$marker" ]; then
    perf_prox=1
    if ! qr_perf_restore; then qr_perf_report || true; exit 3; fi
  fi
  if ! ( qr_await_device ); then
    perf_error='device check/wait failed'
  else
    qr_perf_metadata
    qr_perf_note_device || exit 3
    # Arm cleanup BEFORE attempting the broadcast: transport can fail after delivery.
    mkdir -p "${marker%/*}" && printf '%s\n%s\n' "$QUEST_SERIAL" "$QR_RUN_DIR" > "$marker.tmp" \
      && mv -f "$marker.tmp" "$marker" || exit 3
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
  exit "$rc"
)

qr_perf_device() {
  local rc=0
  qr_set perf 'INFRA: performance capture did not complete (device lock/setup or cancel)'
  qr_set perf_result 3
  qr_perf_note_device || return 3
  rm -f "$QR_RUN_DIR/perf-summary.json" "$QR_RUN_DIR/perf-summary.txt"
  case "${QR_PERF_ACTION:-scripted}" in
    scripted) qr_device_locked qr_perf_locked || rc=$? ;;
    *) qr_device_locked qr_perf_manual_locked || rc=$? ;;
  esac
  # A refused device lock still needs its own fresh machine-readable outcome.
  if [ ! -s "$QR_RUN_DIR/perf-summary.json" ] && [ "$(qr_get perf_result 3)" = 3 ]; then
    local perf_error='device lock/setup failed' perf_model='' perf_package='' perf_mode=report
    local perf_thermal_start=unavailable perf_thermal_end=unavailable
    : > "$QR_RUN_DIR/perf-logcat.txt"
    qr_perf_report || true
  fi
  # Device-lock failures use infrastructure status, not a performance gate fail.
  [ "$(qr_get perf_result 3)" != 3 ] || rc=3
  return "$rc"
}

qr_perf_options() {
  QR_PERF_ACTION=scripted
  case "${1:-}" in
    start|stop)
      QR_PERF_ACTION="$1"; shift
      [ "$#" = 0 ] || { qr_log 'usage: perf start | perf stop (no duration or warm-up options)'; return 1; }
      QR_PERF_SECONDS=0; QR_PERF_WARMUP=0 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --seconds|--warmup)
        [ $# -ge 2 ] || { qr_log "error: perf: $1 needs seconds"; return 1; }
        case "$2" in ''|*[!0-9]*) qr_log 'error: perf: seconds must be integers'; return 1 ;; esac
        if [ "$1" = --seconds ]; then QR_PERF_SECONDS="$2"; else QR_PERF_WARMUP="$2"; fi
        shift ;;
      *) qr_log 'usage: perf [--seconds N] [--warmup S] | perf start | perf stop'; return 1 ;;
    esac
    shift
  done
  QR_PERF_PID_WAIT="${QR_PERF_PID_WAIT:-20}"
  QR_PERF_RESTORE_WAIT="${QR_PERF_RESTORE_WAIT:-10}"
  qr_positive_seconds QR_PERF_PID_WAIT "$QR_PERF_PID_WAIT" || return 1
  qr_positive_seconds QR_PERF_RESTORE_WAIT "$QR_PERF_RESTORE_WAIT" || return 1
  [ "$QR_PERF_ACTION" != scripted ] || qr_positive_seconds 'perf seconds' "$QR_PERF_SECONDS" || return 1
  case "$QR_PERF_WARMUP" in 0) ;; *) qr_positive_seconds 'perf warmup' "$QR_PERF_WARMUP" || return 1 ;; esac
  QR_PERF_SHA=unavailable
}

qr_perf() {
  local serial path run="$QR_RUN_DIR" total=0 rc previous summary='per-device performance captures (see below)'
  QR_PERF_RUN_ROOT="$QR_RUN_DIR"
  QR_PERF_CURSOR="$(qr_lock_dir)/perf-device"
  qr_set device_results ''; qr_set multi_command ''; qr_set overall ''
  if [ "${#QR_SERIALS[@]}" = 1 ]; then qr_perf_device; return $?; fi
  # List reports live under devices/. Retire any earlier single-device verdict
  # before a device cursor can send cancellation reporting to a subfolder.
  if ! rm -f "$run/perf-summary.json" "$run/perf-summary.txt"; then
    qr_log 'error: cannot remove previous single-device performance reports'
    summary='INFRA: cannot remove previous single-device performance reports'
    qr_set perf_result 3
    # Stop still owns the job of consuming reservations and restoring sensors.
    # Carry the cleanup failure into the list verdict rather than stranding them.
    if [ "$QR_PERF_ACTION" != stop ]; then
      qr_set perf "$summary"
      return 3
    fi
    total=3
  fi
  qr_set perf "$summary"
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
