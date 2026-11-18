# shellcheck shell=bash
# Headset mutations share a lock across every consumer repo for the current user.
# Hash the runtime serial, keeping device identifiers out of filenames. Use a fixed
# host-local root (not QR_ROOT or TMPDIR, which may differ between consumers).
qr_device_locked() (
  local key root="/tmp/yetikit-quest-device-locks-$UID" device_lock group="" repo_lock publish=1
  [ -n "${QUEST_SERIAL:-}" ] || qr_die "device lock: QUEST_SERIAL is not selected"
  key="$(printf '%s' "$QUEST_SERIAL" | qr_sha256)" || exit 1
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || qr_die "device lock: cannot hash the device identifier"
  (umask 077; mkdir "$root") 2>/dev/null || true
  [ -d "$root" ] && [ ! -L "$root" ] && [ -O "$root" ] \
    || qr_die "device lock: unsafe lock root $root"
  device_lock="$root/$key.lock"
  repo_lock="$(qr_lock_dir)"
  [ ! -f "$repo_lock/group" ] || group="$(cat "$repo_lock/group")"
  # Reuse the run lock's race-safe stale reclamation, but never its held flag.
  qr_lock_dir() { printf '%s\n' "$device_lock"; }
  QR_LOCK_HELD=""
  # Doctor has no release invocation or run directory to publish.
  [ "$1" != qr_doctor_reconnect ] || publish=0
  if [ "${QR_DEVICE_RESUME_OWNER:-0}" = 1 ] && [ -n "$group" ] &&
    [ "$(cat "$device_lock/pid" 2>/dev/null)" = "$$" ] &&
    [ "$(cat "$device_lock/group" 2>/dev/null)" = "$group" ] && ! qr_group_alive "$group"; then
    # Perf cancellation runs after draining. The cancelled worker may have
    # handed its still-owned lock back to this same live run owner.
    QR_LOCK_HELD=1
  else
    qr_lock_acquire "$publish" || exit 1
  fi
  # Cancellation TERM reaches this shell and adb together. Leave the generation
  # for stale reclamation until the outer owner has drained every worker; an
  # EXIT release here would authorize a second consumer during that drain.
  local cancelled=0
  trap 'cancelled=1; exit 143' HUP INT TERM
  trap '[ "$cancelled" = 1 ] || qr_lock_release' EXIT
  # Record the cancellable worker group too: an owner killed before its workers
  # finish must not authorize a second consumer to mutate the same headset.
  case "$group" in
    ''|0|*[!0-9]*) ;;
    *) printf '%s\n' "$group" > "$device_lock/group" || exit 1 ;;
  esac
  # A manual capture reserves the headset between invocations. Check the
  # reservation only under the normal lock, including for competing repos.
  local QR_DEVICE_MANUAL="$root/$key.manual"
  case "$1" in
    qr_perf_manual_locked|qr_perf_manual_recover_locked) ;;
    *) if [ -e "$QR_DEVICE_MANUAL" ]; then
         qr_log "error: device $QUEST_SERIAL has a pending manual capture; run perf stop from its owning checkout and log root"
         exit 3
       fi ;;
  esac
  "$@"
)
