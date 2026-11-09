# shellcheck shell=bash
# Ordered multi-headset work. Never acquire a second device lock while holding one.
# Single-device dispatch deliberately stays on the original code/artifact path.
qr_serials() {
  local serial list="${QUEST_SERIAL//,/ }"
  QR_SERIALS=()
  # Read tokens literally: serials must never undergo pathname expansion.
  while IFS= read -r serial; do
    [ -z "$serial" ] || QR_SERIALS+=("$serial")
  done < <(printf '%s\n' "$list" | tr ' \t' '\n\n')
  [ "${#QR_SERIALS[@]}" -gt 0 ] || { qr_log 'error: QUEST_SERIAL list is empty'; return 1; }
  QUEST_SERIAL="${QR_SERIALS[0]}"
}

# Collision-free byte encoding, including percent, dot, slash and colon. LC_ALL
# makes Bash 3.2 substring indexing byte-based even for non-ASCII input.
qr_serial_path() {
  local LC_ALL=C value="$1" c i
  for ((i=0; i<${#value}; i++)); do
    c="${value:i:1}"
    case "$c" in [a-zA-Z0-9_-]) printf '%s' "$c" ;; *) printf '%%%02X' "'$c" ;; esac
  done
}

qr_worst() {
  case "$1:$2" in 1:*|*:1) echo 1 ;; 0:0) echo 0 ;; *) echo 3 ;; esac
}

qr_multi_record() {
  local step="$1" rc="$2" detail="$3" outcome=INFRA
  case "$rc" in 0) outcome=OK ;; 1) [ "$step" != launch ] || outcome=CRASH ;; esac
  qr_set "outcome-$step" "$outcome: $detail"
}

# This entire callback owns exactly one device lock, including crash rollback.
qr_multi_device_locked() {
  local cmd="$1" apk="$2" force="$3" rollback="$4" rc=0 next=0
  if [ "$cmd" = all ] || [ "$cmd" = install ] || [ "$cmd" = rollback ]; then
    local label=install flags=""
    [ "$cmd" != rollback ] || { label=rollback; flags=-d; }
    ( qr_install_apk_locked "$apk" "$force" "$label" "$flags" ) || rc=3
    qr_multi_record "$label" "$rc" "$(qr_get install); idle: $(qr_get idle)"
    if [ "$rc" != 0 ]; then
      [ "$cmd" != all ] || qr_multi_record launch 3 'skipped: install failed'
      return 3
    fi
  fi
  if [ "$cmd" = all ] || [ "$cmd" = launch ]; then
    ( qr_launch_locked ) || rc=$?
    # Setup/lock failures must not accidentally become confirmed crashes.
    if [ "$rc" != 0 ]; then
      case "$(qr_get launch)" in CRASH:*) rc=1 ;; *) rc=3 ;; esac
    fi
    qr_multi_record launch "$rc" "$(qr_get launch)"
    if [ "$cmd" = all ] && [ "$rc" = 1 ] && [ -n "$rollback" ]; then
      qr_log "launch[$QUEST_SERIAL] shows a crash: rolling back"
      ( qr_install_apk_locked "$rollback" "$force" rollback -d ) || next=3
      qr_multi_record rollback "$next" "$(qr_get install); idle: $(qr_get idle)"
    fi
  fi
  return "$rc"
}

qr_multi_device() (
  local cmd="$1" apk="$2" force="$3" rollback="$4" rc=0
  # Defaults survive a lock refusal or an unexpected early exit in the callback.
  case "$cmd" in
    all) qr_multi_record install 3 'device lock/setup failed'; qr_multi_record launch 3 'skipped: device lock/setup failed' ;;
    *) qr_multi_record "$cmd" 3 'device lock/setup failed' ;;
  esac
  qr_set launch 'INFRA: launch did not complete (see release.log)'
  qr_device_locked qr_multi_device_locked "$cmd" "$apk" "$force" "$rollback" || rc=$?
  if [ "$rc" = 1 ]; then
    case "$(qr_get outcome-launch '')" in CRASH:*) ;; *) rc=3 ;; esac
  fi
  return "$rc"
)

# Primary APK has already been verified for all. Standalone installs verify once
# here, before any headset work. Rollback verification has separate logs and may
# never replace the primary APK/provenance fields in the run's summary.
qr_multi() {
  local cmd="$1" apk="${2:-}" force="${3:-0}" rollback="${4:-}" serial path step result rc total=0
  local run="$QR_RUN_DIR" verified_dir previous
  qr_set device_results ''
  qr_set multi_command "$cmd"
  qr_set multi_result 3
  qr_set overall 'INFRA: device work did not complete'
  # Root device fields belong to the old single-device attempt, not this list.
  # Invalidate them before verification can stop us without any device rows.
  for step in idle backup install data_hash mic launch; do
    qr_set "$step" "not run at root (list $cmd; see per-device results)"
  done
  if [ "$cmd" = install ] || [ "$cmd" = rollback ]; then
    ( qr_java_setup && qr_verify "$apk" ) || return 3
  fi
  QR_VERIFIED_APK="$apk"
  QR_VERIFIED_ROLLBACK_APK=''
  if [ -n "$rollback" ]; then
    verified_dir="$run/rollback-verify"
    mkdir -p "$verified_dir" || return 3
    ( QR_RUN_DIR="$verified_dir"; qr_verify "$rollback" ) || return 3
    QR_VERIFIED_ROLLBACK_APK="$rollback"
  fi
  for serial in "${QR_SERIALS[@]}"; do
    path="$(qr_serial_path "$serial")"
    mkdir -p "$run/devices/$path" || return 3
    rc=0
    ( QUEST_SERIAL="$serial"; QR_RUN_DIR="$run/devices/$path"
      QR_BACKUP_DEVICE_SUFFIX="-$path"
      rm -f "$QR_RUN_DIR"/summary/outcome-*
      qr_multi_device "$cmd" "$apk" "$force" "$rollback"
    ) || rc=$?
    total="$(qr_worst "$total" "$rc")"
    for step in install launch rollback; do
      result="$(QR_RUN_DIR="$run/devices/$path" qr_get "outcome-$step" '')"
      [ -n "$result" ] || continue
      # Append via qr_set so summaries remain atomic; no raw serial in a filename.
      previous="$(qr_get device_results '')"
      qr_set device_results "${previous:+$previous$'\n'}$step[$serial]: $result"
    done
  done
  qr_set multi_result "$total"
  case "$total" in 0) result=OK ;; 1) result=CRASH ;; *) result=INFRA ;; esac
  qr_set overall "$result (exit $total)"
  return "$total"
}

qr_multi_command() {
  local cmd="$1" apk='' force=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --force) force=1 ;; *) apk="$1" ;; esac
    shift
  done
  if [ "$cmd" = install ]; then [ -n "$apk" ] || apk="$(qr_get apk '')"; fi
  if [ "$cmd" = rollback ] && [ -z "$apk" ]; then qr_die 'rollback: name the previous APK'; fi
  qr_multi "$cmd" "$apk" "$force"
}
