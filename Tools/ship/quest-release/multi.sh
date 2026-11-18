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

# Escape uppercase too, so case-folding filesystems cannot alias distinct
# serials. LC_ALL makes Bash 3.2 index bytes even for non-ASCII input.
qr_serial_path() {
  local LC_ALL=C value="$1" c i
  for ((i=0; i<${#value}; i++)); do
    c="${value:i:1}"
    case "$c" in [a-z0-9_-]) printf '%s' "$c" ;; *) printf '%%%02X' "'$c" ;; esac
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

qr_multi_install_detail() {
  printf '%s; idle: %s; permissions: %s' "$(qr_get install)" "$(qr_get idle)" "$(qr_get permissions)"
}

# This entire callback owns exactly one device lock, including crash rollback.
qr_multi_device_locked() {
  local cmd="$1" apk="$2" force="$3" rollback="$4" rc=0 next=0
  if [ "$cmd" = all ] || [ "$cmd" = install ] || [ "$cmd" = rollback ]; then
    local label=install flags=""
    [ "$cmd" != rollback ] || { label=rollback; flags=-d; }
    ( qr_install_apk_locked "$apk" "$force" "$label" "$flags" ) || rc=3
    qr_multi_record "$label" "$rc" "$(qr_multi_install_detail)"
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
      qr_multi_record rollback "$next" "$(qr_multi_install_detail)"
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
  case "$cmd" in all|launch) qr_set launch 'INFRA: launch did not complete (see release.log)' ;; esac
  qr_device_locked qr_multi_device_locked "$cmd" "$apk" "$force" "$rollback" || rc=$?
  if [ "$rc" = 1 ]; then
    case "$cmd:$(qr_get outcome-launch '')" in all:CRASH:*|launch:CRASH:*) ;; *) rc=3 ;; esac
  fi
  return "$rc"
)

qr_multi_steps() {
  case "$1" in all) printf '%s\n' install launch rollback ;; *) printf '%s\n' "$1" ;; esac
}

qr_multi_begin() {
  local cmd="$1" step
  qr_set device_results ''
  qr_set multi_command "$cmd"
  qr_set multi_result 3
  qr_set overall 'INFRA: device work did not complete'
  # Replace only the step results owned by this invocation. In particular,
  # standalone launch must not overwrite the latest list install results.
  while IFS= read -r step; do
    qr_set "device_results_$step" ''
  done < <(qr_multi_steps "$cmd")
  # Root device fields belong to the old single-device attempt, not this list.
  for step in idle backup install data_hash permissions launch; do
    qr_set "$step" "not run at root (list $cmd; see per-device results)"
  done
}

qr_multi_append() {
  local key="device_results_$1" previous
  previous="$(qr_get "$key" '')"
  qr_set "$key" "${previous:+$previous$'\n'}$1[$2]: $3"
}

qr_multi_finish() {
  local step rows summary='' rc result
  for step in install launch rollback; do
    rows="$(qr_get "device_results_$step" '')"
    [ -z "$rows" ] || summary="${summary:+$summary$'\n'}$rows"
  done
  qr_set device_results "$summary"
  # The device reducer alone can certify a crash or success. An exit 1 from
  # argument parsing, preparation or verification is not evidence of a crash.
  rc="$(qr_get multi_result 3)"
  case "$rc" in 0) result=OK ;; 1) result=CRASH ;; *) result=INFRA; rc=3 ;; esac
  qr_set overall "$result (exit $rc)"
  return "$rc"
}

# The primary snapshot was verified by the caller before any headset work.
qr_multi() {
  local cmd="$1" force="$3" serial path step result rc total=0
  local run="$QR_RUN_DIR" QR_VERIFIED_APK="$2" QR_VERIFIED_ROLLBACK_APK="${4:-}"
  if [ -n "$QR_VERIFIED_ROLLBACK_APK" ]; then
    qr_verify_rollback_snapshot "$QR_VERIFIED_ROLLBACK_APK" "$5" || return 3
  fi
  for serial in "${QR_SERIALS[@]}"; do
    path="$(qr_serial_path "$serial")"
    if ! mkdir -p "$run/devices/$path"; then
      qr_log "error: cannot create device directory for $serial: $run/devices/$path"
      if [ "$cmd" = all ]; then
        qr_multi_append install "$serial" 'INFRA: device directory unavailable'
        qr_multi_append launch "$serial" 'INFRA: skipped: device directory unavailable'
      else
        qr_multi_append "$cmd" "$serial" 'INFRA: device directory unavailable'
      fi
      total="$(qr_worst "$total" 3)"
      continue
    fi
    rc=0
    ( QUEST_SERIAL="$serial"; QR_RUN_DIR="$run/devices/$path"
      QR_BACKUP_DEVICE_SUFFIX="-$path"
      # Only all has an optional outcome that might otherwise be stale.
      if [ "$cmd" = all ]; then rm -f "$QR_RUN_DIR/summary/outcome-rollback"; fi
      qr_multi_device "$cmd" "$QR_VERIFIED_APK" "$force" "$QR_VERIFIED_ROLLBACK_APK"
    ) || rc=$?
    total="$(qr_worst "$total" "$rc")"
    while IFS= read -r step; do
      result="$(QR_RUN_DIR="$run/devices/$path" qr_get "outcome-$step" '')"
      [ -n "$result" ] || continue
      qr_multi_append "$step" "$serial" "$result"
    done < <(qr_multi_steps "$cmd")
  done
  qr_set multi_result "$total"
  return "$total"
}

qr_multi_command() {
  local cmd="$1" apk='' force=0 snapshot=''
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --force) force=1 ;; *) apk="$1" ;; esac
    shift
  done
  if [ "$cmd" = install ]; then [ -n "$apk" ] || apk="$(qr_get apk '')"; fi
  if [ "$cmd" = rollback ] && [ -z "$apk" ]; then qr_die 'rollback: name the previous APK'; fi
  if [ "$cmd" != launch ]; then
    snapshot="$(qr_apk_snapshot "$apk" primary)" || return 3
    ( qr_java_setup && qr_verify "$snapshot" "$apk" ) || return 3
  fi
  qr_multi "$cmd" "$snapshot" "$force"
}
