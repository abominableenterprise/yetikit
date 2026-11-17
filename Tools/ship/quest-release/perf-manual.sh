# shellcheck shell=bash
# Manual sessions reserve the serial in the shared device-lock root. The file is
# modified only under the device lock. An owner-only record means restoration
# is pending but the window was never committed (or stop already consumed it).
qr_perf_manual_save() {
  jq -n --arg owner "$manual_owner" --arg dir "$QR_RUN_DIR" "$@" \
    > "$marker.tmp" && mv -f "$marker.tmp" "$marker"
}

qr_perf_manual_adb() {
  QR_TIMEBOX_KILL_AFTER=1 qr_timebox 10 adb -s "$QUEST_SERIAL" "$@"
}

# Journal only devices this invocation actually took responsibility for. A
# duplicate start, unmatched stop or cancel before setup must not undo a window.
qr_perf_manual_note() {
  local journal="${QR_PERF_CURSOR%/*}/perf-manual"
  mkdir -p "$journal" && printf '%s\n' "$QUEST_SERIAL" > "$journal/${marker##*/}.tmp" &&
    mv -f "$journal/${marker##*/}.tmp" "$journal/${marker##*/}"
}

qr_perf_manual_begin() {
  local scripted_marker
  if [ -e "$marker" ]; then
    perf_error='manual capture already pending; run perf stop from the owning checkout and log root'; return 3
  fi
  scripted_marker="$(qr_perf_marker)" || return 3
  if [ -f "$scripted_marker" ]; then
    perf_error='scripted proximity restoration is pending; run scripted perf first'; return 3
  fi
  ( qr_await_device ) || { perf_error='device check/wait failed'; return 3; }
  qr_perf_metadata qr_perf_manual_adb || return 3
  [ -z "$perf_error" ] || return 3
  perf_pid="$(qr_launch_pid qr_perf_manual_adb)" && [[ "$perf_pid" =~ ^[0-9]+$ ]] &&
    qr_perf_identity qr_perf_manual_adb || { perf_error='target app has no unique foreground PID; launch it before perf start'; return 3; }
  perf_thermal_start="$(qr_perf_thermal qr_perf_manual_adb)"
  qr_perf_note_device && qr_perf_manual_note &&
    qr_perf_manual_save '{owner:$owner, dir:$dir}' || return 3
  perf_prox=1
  qr_perf_manual_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close \
    > "$QR_RUN_DIR/perf-prox.log" 2>&1 || { perf_error='adb proximity override failed'; return 3; }
  qr_perf_clock || return 3
  qr_perf_manual_save --arg start "$perf_clock" --arg host "$perf_clock_host_ms" \
    --arg pid "$perf_pid" --arg package "$QR_PKG" --arg model "$perf_model" \
    --arg metadata "$perf_package" --arg sha "$QR_PERF_SHA" --arg mode "$perf_mode" \
    --arg thermal "$perf_thermal_start" --argjson stale "$QR_PERF_MAX_STALE" --argjson app "$QR_PERF_MAX_APP" \
    '{owner:$owner, dir:$dir, start:$start, host:$host, pid:$pid, package:$package, model:$model,
      metadata:$metadata, sha:$sha, mode:$mode, thermal:$thermal, stale:$stale, app:$app}' || return 3
  qr_set perf "Manual capture started on $QUEST_SERIAL; run perf stop to finish" && qr_set perf_result 0 || return 3
}

qr_perf_manual_end() {
  local record elapsed
  if [ ! -e "$marker" ]; then perf_error='no matching perf start for this device'; return 3; fi
  record="$(jq -ec --arg owner "$manual_owner" 'select(.owner == $owner)' "$marker")" || {
    perf_error='manual capture is not owned by this checkout and log root (or its record is unreadable)'; return 3;
  }
  qr_perf_manual_note || return 3
  perf_prox=1
  # Once stop owns the reservation, consume the window before querying the
  # device. An interrupted stop or failed restore must never extend that window.
  qr_perf_manual_save '{owner:$owner, dir:$dir}' || return 3
  if ! jq -e --arg package "$QR_PKG" '
    .package == $package and (.start | strings | test("^(0|[1-9][0-9]{0,11})\\.[0-9]{9}$")) and
    (.pid | strings | test("^[0-9]+$")) and (.host | strings | test("^[0-9]+$"))
  ' <<< "$record" >/dev/null; then
    perf_error='no usable manual perf window (interrupted capture or package changed); restoring proximity only'; return 3
  fi
  perf_pid="$(jq -r .pid <<< "$record")"
  perf_model="$(jq -r .model <<< "$record")"
  perf_package="$(jq -r .metadata <<< "$record")"
  perf_mode="$(jq -r .mode <<< "$record")"
  perf_thermal_start="$(jq -r .thermal <<< "$record")"
  QR_PERF_SHA="$(jq -r .sha <<< "$record")"
  QR_PERF_MAX_STALE="$(jq -r .stale <<< "$record")"
  QR_PERF_MAX_APP="$(jq -r .app <<< "$record")"
  qr_perf_note_device || return 3
  # Take the stop edge before endpoint probes and the dump, so slow probes
  # cannot extend the window. Reject a backwards or materially shifted clock.
  qr_perf_clock || return 3
  perf_start="$(jq -r .start <<< "$record")"
  elapsed="$(jq -ner --argjson start "$perf_start" --argjson finish "$perf_clock" \
    --argjson host "$(jq -r .host <<< "$record")" --argjson now "$perf_clock_host_ms" '
    ($finish - $start) as $seconds | (($now - $host) / 1000) as $hostSeconds |
    select($hostSeconds >= 0 and $seconds > 0 and (($seconds - $hostSeconds) | fabs) <= 1) |
    ($seconds * 1000 | round) / 1000')" || { perf_error='manual capture clock moved or window is empty'; return 3; }
  perf_end="$perf_clock"
  QR_PERF_SECONDS="$elapsed"
  qr_perf_identity qr_perf_manual_adb || { perf_error='target app identity/foreground lost during manual capture'; return 3; }
  # Compare fixed-width timestamp strings before the report's numeric filter;
  # rounding a nanosecond epoch to a float can admit a pre-window sample.
  if ! (set -o pipefail
    qr_perf_manual_adb logcat -d -v epoch -v usec --pid="$perf_pid" -s VrApi 2> "$QR_RUN_DIR/perf-adb.err" |
      LC_ALL=C awk -v start="$perf_start" -v end="$perf_end" '
        function epoch(t, parts) {
          split(t, parts, /[.]/)
          return "t" sprintf("%012.0f", parts[1]) substr(parts[2] "000000000", 1, 9)
        }
        BEGIN { start = epoch(start); end = epoch(end) }
        $1 ~ /^[0-9]+\.[0-9]+$/ && epoch($1) >= start && epoch($1) < end
      ' > "$QR_RUN_DIR/perf-logcat.txt"
  ); then perf_error='adb logcat capture failed'; fi
  perf_thermal_end="$(qr_perf_thermal qr_perf_manual_adb)"
}

qr_perf_manual_locked() {
  local marker="$QR_DEVICE_MANUAL" manual_owner perf_prox=0 perf_error='' rc=0
  local perf_model='' perf_package='' perf_mode=report perf_pid='' perf_scene=unavailable
  local perf_start=null perf_end=null perf_thermal_start=unavailable perf_thermal_end=unavailable
  local perf_clock perf_clock_host_ms
  # Pair only within the same checkout and log root, not the mutable current run.
  manual_owner="$(qr_perf_manual_owner)" || return 3
  # An artifact write error must not prevent stop from attempting restoration.
  : > "$QR_RUN_DIR/perf-logcat.txt" || { [ "$QR_PERF_ACTION" = stop ] || return 3; }
  if [ "$QR_PERF_ACTION" = start ]; then
    qr_perf_manual_begin && return 0
  else
    qr_perf_manual_end || rc=3
  fi
  if [ "$QR_PERF_ACTION" = start ] || [ "$rc" = 3 ]; then
    perf_error="${perf_error:-could not save or read manual capture state}"
  fi
  [ -z "$perf_error" ] || qr_log "INFRA: $perf_error"
  qr_perf_restore || perf_error="${perf_error:-could not clear the manual capture reservation}"
  # Manual logcat is already bounded with exact string comparisons.
  perf_start=null; perf_end=null
  qr_perf_report
}

qr_perf_manual_owner() {
  local logs repo
  logs="$(cd "$QR_LOGS" && pwd -P)" && repo="$(cd "$QR_REPO" && pwd -P)" || return 3
  jq -nc --arg repo "$repo" --arg logs "$logs" '[$repo, $logs] | tostring'
}

qr_perf_manual_cancel_device() (
  IFS= read -r QUEST_SERIAL < "$1" || return 3
  if ! QR_DEVICE_RESUME_OWNER=1 qr_device_locked qr_perf_manual_recover_locked; then
    printf 'WARN: manual capture recovery failed; retry perf stop for %s from the owning checkout and log root\n' "$QUEST_SERIAL"
  fi
)

qr_perf_manual_recover_locked() {
  local marker="$QR_DEVICE_MANUAL" owner perf_prox=1 perf_error=''
  [ -e "$marker" ] || return 0
  owner="$(qr_perf_manual_owner)" || return 3
  QR_RUN_DIR="$(jq -er --arg owner "$owner" 'select(.owner == $owner) | .dir | strings' "$marker")" || return 3
  # Invalidate the window before attempting restoration, even if adb is down.
  local manual_owner="$owner"
  qr_perf_manual_save '{owner:$owner, dir:$dir}' || return 3
  qr_perf_restore
}
