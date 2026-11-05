# shellcheck shell=bash
# Headset mutations share a lock across every consumer repo for the current user.
# Hash the runtime serial, keeping device identifiers out of filenames. Use a fixed
# host-local root (not QR_ROOT or TMPDIR, which may differ between consumers).
qr_device_locked() (
  local key root="/tmp/yetikit-quest-device-locks-$UID" device_lock group="" repo_lock
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
  qr_lock_acquire || exit 1
  trap 'qr_lock_release' EXIT
  # Record the cancellable worker group too: an owner killed before its workers
  # finish must not authorize a second consumer to mutate the same headset.
  case "$group" in
    ''|0|*[!0-9]*) ;;
    *) printf '%s\n' "$group" > "$device_lock/group" || exit 1 ;;
  esac
  "$@"
)
