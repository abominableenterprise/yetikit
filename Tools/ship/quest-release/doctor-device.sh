# shellcheck shell=bash
# Doctor's device probe and its single recovery attempt share one deadline.
# The lock encloses recovery's timebox so it releases only after adb is drained.
qr_doctor_reconnect() {
  local remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return 124
  ( qr_timebox_supervise "$remaining" 0 qr_doctor_reconnect_probe "$1" )
}

qr_doctor_reconnect_probe() {
  # Only reset the selected transport, never `reconnect offline` (server-wide).
  printf '[quest-release] doctor: %s; reconnecting and waiting for device\n' "$1" >&2
  qr_adb reconnect >/dev/null 2>&1 || true # the transport may still be absent
  qr_adb wait-for-device >/dev/null 2>&1 || { echo "$1; adb wait-for-device failed"; return 1; }
  qr_device_status
}

qr_doctor_device() {
  local why verdict rc=0 deadline result
  command -v adb >/dev/null 2>&1 || { qr_doctor_line FAIL device "no adb on PATH"; qr_doctor_line warn idle "not checked (no device)"; return; }
  deadline=$((SECONDS + QR_DEVICE_CHECK_WAIT))
  # Use the in-shell supervisor: the timed probe is a shell function.
  why="$(qr_timebox_supervise "$QR_DEVICE_CHECK_WAIT" 0 qr_device_status doctor)" || rc=$?
  if [ "$rc" = 2 ]; then
    rc=0
    result="$(qr_device_locked qr_doctor_reconnect "$why")" || rc=$?
    why="${result:-$why; reconnect unavailable (see stderr)}"
  fi
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 124 ]; then why="Quest $QUEST_SERIAL: device check timed out after ${QR_DEVICE_CHECK_WAIT}s"; fi
    qr_doctor_line FAIL device "$why"
    qr_doctor_line warn idle "not checked (no device)"
    return
  fi
  qr_doctor_line ok device "$why"
  verdict="$(qr_idle_verdict)" || rc=$?
  case "$rc" in
    0) qr_doctor_line ok idle "idle ($verdict)" ;;
    1) qr_doctor_line warn idle "in use ($verdict): install would refuse without --force" ;;
    *) qr_doctor_line warn idle "unknown ($verdict): install would refuse, even with --force" ;;
  esac
}
