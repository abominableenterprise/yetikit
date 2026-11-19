# shellcheck shell=bash
# Headset mutations share a lock across every consumer repo for the current user.
# Hash the runtime serial, keeping device identifiers out of filenames. Use a fixed
# host-local root (not QR_ROOT or TMPDIR, which may differ between consumers).
qr_device_locked() (
  local key root="/tmp/yetikit-quest-device-locks-$UID" device_lock group="" repo_lock group_status=0
  [ -n "${QUEST_SERIAL:-}" ] || qr_die "device lock: QUEST_SERIAL is not selected"
  key="$(printf '%s' "$QUEST_SERIAL" | qr_sha256)" || exit 1
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || qr_die "device lock: cannot hash the device identifier"
  (umask 077; mkdir "$root") 2>/dev/null || true
  [ -d "$root" ] && [ ! -L "$root" ] && [ -O "$root" ] \
    || qr_die "device lock: unsafe lock root $root"
  device_lock="$root/$key.lock"
  local owner_pid="$$" supervisor previous_supervisor
  local QR_DEVICE_WORKER_ROOT QR_DEVICE_SUPERVISOR QR_DEVICE_LOCK_READ=1
  # The wrapper can outlive the release owner, including during registration.
  # $$ is not this subshell's PID (and Bash 3.2 has no BASHPID).
  supervisor="$(exec sh -c 'printf "%s\n" "$PPID"')" || exit 1
  [[ "$supervisor" =~ ^[1-9][0-9]*$ ]] || exit 1
  if [ "$1" != qr_doctor_reconnect ]; then
    repo_lock="$(qr_lock_dir)"
    [ ! -f "$repo_lock/group" ] || group="$(cat "$repo_lock/group")"
  fi
  # Reuse the run lock's race-safe stale reclamation, but never its held flag.
  qr_lock_dir() { printf '%s\n' "$device_lock"; }
  QR_LOCK_HELD=""
  if [ "${QR_DEVICE_RESUME_OWNER:-0}" = 1 ] && [ -n "$group" ] &&
    [ "$(cat "$device_lock/pid" 2>/dev/null)" = "$$" ] &&
    [ "$(cat "$device_lock/group" 2>/dev/null)" = "$group" ]; then
    qr_group_alive "$group" || group_status=$?
  fi
  if [ "$group_status" = 1 ]; then
    # Perf cancellation runs after draining. Resume only if the old wrapper
    # and every isolated group have stopped, even for this same run owner.
    previous_supervisor="$(cat "$device_lock/supervisor" 2>/dev/null)"
    if qr_lock_process_busy "$previous_supervisor" ||
       ! (cd "$device_lock" && ! qr_lock_workers_busy "$group"); then
      qr_log 'error: cannot resume device lock while its previous workers may be active'
      exit 1
    fi
    printf '%s\n' "$supervisor" > "$device_lock/supervisor.tmp" &&
      mv -f "$device_lock/supervisor.tmp" "$device_lock/supervisor" || exit 1
    QR_LOCK_HELD=1
  else
    # Publish the wrapper and enclosing step before allowing any mutation.
    qr_lock_acquire 0 "$owner_pid" "$supervisor" "$group" || exit 1
  fi
  # Cancellation TERM reaches this shell and adb together. Leave the generation
  # for stale reclamation until the outer owner has drained every worker; an
  # EXIT release here would authorize a second consumer during that drain.
  local cancelled=0
  trap 'cancelled=1; exit 143' HUP INT TERM
  # A failed drain keeps this generation visible to other checkouts. The
  # wrapper itself is still in the step group, so inspect only isolated groups.
  trap '
    if [ "$cancelled" != 1 ]; then
      if (cd "$device_lock" && ! qr_lock_workers_busy ""); then
        qr_lock_release "$owner_pid"
      else
        exit 1
      fi
    fi
  ' EXIT
  QR_DEVICE_WORKER_ROOT="$(mktemp -d "$device_lock/step.XXXXXXXXXX")" || exit 1
  QR_DEVICE_SUPERVISOR="$supervisor"
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
