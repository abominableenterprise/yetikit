# shellcheck shell=bash
# Keep one pending restoration per serial in the run, independently of the
# current invocation's report target. The run lock protects both records.
qr_perf_marker() {
  local key
  key="$(printf '%s' "$QUEST_SERIAL" | qr_sha256)" || return 3
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 3
  printf '%s/perf-pending/%s\n' "$QR_PERF_RUN_ROOT" "$key"
}

qr_perf_note_device() {
  local cursor="$QR_PERF_CURSOR"
  printf '%s\n%s\n%s\n' "$QUEST_SERIAL" "$QR_RUN_DIR" "$QR_PERF_SHA" > "$cursor.tmp" && mv -f "$cursor.tmp" "$cursor"
}

qr_perf_restore() {
  [ "$perf_prox" = 1 ] || return 0
  local log="$QR_RUN_DIR/perf-prox.log"
  # Do not skip the safety broadcast just because its log cannot be opened.
  if ! ( : >> "$log" ); then
    qr_log 'WARN: cannot write perf-prox.log; attempting proximity restoration anyway'
    log=/dev/null
  fi
  if QR_TIMEBOX_KILL_AFTER=1 qr_timebox "${QR_PERF_RESTORE_WAIT:-10}" adb -s "$QUEST_SERIAL" shell am broadcast -a com.oculus.vrpowermanager.automation_disable >> "$log" 2>&1; then
    perf_prox=0
    # A failed attempt leaves its record for EXIT, cancellation or the next capture.
    [ -z "${marker:-}" ] || rm -f "$marker"
  else
    local warning="WARN: proximity sensor may still be disabled; run: adb -s $QUEST_SERIAL shell am broadcast -a com.oculus.vrpowermanager.automation_disable"
    perf_error="${perf_error:+$perf_error; }adb proximity restoration failed or timed out (see perf-prox.log); $warning"
    qr_log "$warning"
    return 3
  fi
}

qr_perf_recover_device() (
  local marker="$1" perf_prox=1 perf_error=''
  [[ "${marker##*/}" =~ ^[0-9a-f]{64}$ ]] || return 3
  {
    IFS= read -r QUEST_SERIAL && IFS= read -r QR_RUN_DIR
  } < "$marker" || return 3
  # Never broadcast without device ownership. If a different consumer has
  # the headset, leave the record pending and surface the manual recovery.
  if ! QR_DEVICE_RESUME_OWNER=1 qr_device_locked qr_perf_restore; then
    printf 'WARN: proximity restoration failed or timed out; run: adb -s %s shell am broadcast -a com.oculus.vrpowermanager.automation_disable\n' "$QUEST_SERIAL"
  fi
)

qr_perf_cancel_report() (
  local dir="$1" QR_PERF_SHA="$2" warning="$3"
  local perf_error="capture cancelled${warning:+; $warning}" perf_model='' perf_package='' perf_mode=report perf_reported=0
  local perf_thermal_start=unavailable perf_thermal_end=unavailable
  QR_RUN_DIR="$dir"
  mkdir -p "$QR_RUN_DIR" || return 3
  [ -f "$QR_RUN_DIR/perf-logcat.txt" ] || : > "$QR_RUN_DIR/perf-logcat.txt"
  qr_perf_report || true # Publishing INFRA also returns 3.
  [ "$perf_reported" = 1 ]
)

# The owner runs this only after draining the worker group. Even with no pending
# sensor restoration, replace the previous invocation's outcome with cancellation.
qr_perf_cancel() {
  local QR_PERF_RUN_ROOT="$QR_RUN_DIR" cursor marker warning warnings='' active_warning=''
  local serial='' dir="$QR_RUN_DIR" sha=unavailable summary='INFRA: capture cancelled'
  cursor="$(qr_lock_dir)/perf-device"
  if [ -f "$cursor" ]; then
    { IFS= read -r serial && IFS= read -r dir && IFS= read -r sha; } < "$cursor"
  fi
  local recovery_dir="$QR_PERF_RUN_ROOT/perf-pending" recovery=qr_perf_recover_device entry_serial
  if [ "${QR_PERF_ACTION:-scripted}" != scripted ]; then
    recovery_dir="${cursor%/*}/perf-manual"
    recovery=qr_perf_manual_cancel_device
  fi
  for marker in "$recovery_dir"/*; do
    case "${marker##*/}" in *.tmp) continue ;; esac
    [ -f "$marker" ] || continue
    warning="$("$recovery" "$marker")"
    [ -n "$warning" ] || continue
    warnings="${warnings:+$warnings$'\n'}$warning"
    IFS= read -r entry_serial < "$marker"
    if [ "$entry_serial" = "$serial" ]; then active_warning="$warning"; fi
  done
  if ! qr_perf_cancel_report "$dir" "$sha" "$active_warning"; then
    summary="$summary (per-device performance summary could not be published)"
  fi
  qr_set perf "$summary${warnings:+$'\n'$warnings}"
  qr_set perf_result 3
  qr_set device_results ''
  qr_set multi_command ''
  qr_set overall ''
}
