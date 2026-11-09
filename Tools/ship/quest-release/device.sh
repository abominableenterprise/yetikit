# shellcheck shell=bash
# quest-release `install <apk>`, `rollback <apk>` and `launch`: the headset steps. Every adb call goes through qr_adb
# (always `-s $QUEST_SERIAL`). Never uninstall, clear app data or grant/revoke a permission. Configured data
# files may contain credentials: their contents only ever go to a backup file, never to the terminal. Sourced by Tools/ship/quest-release.sh.

# logcat lines: Unity errors (threadtime "... E Unity   : ..." or brief "E/Unity"); every FATAL / AndroidRuntime line is
# reported. A game-attributed crash is FATAL, a native "Fatal signal" / tombstone, or an error-level AndroidRuntime
# line (the JVM crash handler; a D-level one is only the am tool starting).
QR_RE_UNITY_ERR='(^|[[:space:]])E(/|[[:space:]]+)Unity'
QR_RE_FATAL='FATAL|Fatal signal|AndroidRuntime'
QR_RE_CRASH='FATAL|Fatal signal|(^|[[:space:]])[EF](/|[[:space:]]+)AndroidRuntime'

# Public launch outcomes: only a confirmed crash may authorize rollback.
QR_LAUNCH_OK=0
QR_LAUNCH_CRASH=1
QR_LAUNCH_INFRA=3

qr_adb() { adb -s "$QUEST_SERIAL" "$@"; }
qr_adb_shell() { qr_adb shell "$@" 2>/dev/null | tr -d '\r'; }

# Prints why the Quest cannot be used and returns 1, or prints its state and returns 0. Read-only (doctor uses it).
qr_device_status() {
  local state maker
  state="$(qr_adb get-state 2>/dev/null)" || { echo "Quest $QUEST_SERIAL: adb get-state failed"; return 1; }
  state="${state//$'\r'/}"
  [ "$state" = device ] || { echo "Quest $QUEST_SERIAL is not connected (adb state '${state:-none}')"; return 1; }
  maker="$(qr_adb shell getprop ro.product.manufacturer 2>/dev/null)" \
    || { echo "Quest $QUEST_SERIAL: adb manufacturer query failed"; return 1; }
  maker="${maker//$'\r'/}"
  [ "$maker" = Oculus ] || { echo "device $QUEST_SERIAL is made by '${maker:-unknown}', not Oculus: refusing"; return 1; }
  echo "Quest $QUEST_SERIAL: adb state device, manufacturer Oculus"
}

qr_check_device() { local why; why="$(qr_device_status)" || qr_die "$why"; }

# The Quest can drop off adb briefly: when its state is not `device`, wait up to
# QUEST_ADB_WAIT (120) s for it with `adb wait-for-device`, then check it as usual (qr_check_device fails as before).
qr_await_device() {
  local state
  state="$(qr_adb get-state 2>/dev/null | tr -d '\r')"
  if [ "$state" != device ]; then
    qr_log "Quest $QUEST_SERIAL adb state '${state:-none}': waiting up to ${QR_ADB_WAIT:-120}s (adb wait-for-device)"
    qr_timebox "${QR_ADB_WAIT:-120}" adb -s "$QUEST_SERIAL" wait-for-device >/dev/null 2>&1 || true
  fi
  qr_check_device
}

# sha256 of a data file on the device, "missing" only when its parent storage is accessible and the file is absent.
# A failed adb call, unreadable directory/file, or unexpected sha256sum output must never be treated as absence.
qr_device_sha() {
  local p="$QR_DATA_DIR/$1" out hash
  out="$(qr_adb shell "if ! cd '$QR_DATA_DIR' 2>/dev/null; then echo unknown; elif ! listing=\$(ls -A . 2>/dev/null); then echo unknown; elif ! printf '%s\\n' \"\$listing\" | grep -Fxq '$1'; then echo missing; elif [ -f '$p' ]; then sha256sum '$p' || echo unknown; else echo unknown; fi" 2>/dev/null)" \
    || { printf 'unknown\n'; return; }
  out="${out//$'\r'/}"
  if [ "$out" = missing ]; then
    printf 'missing\n'
  else
    hash="${out%% *}"
    if [[ "$out" == *' '* ]] && [[ "$out" != *$'\n'* ]] && [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
      printf '%s\n' "$hash"
    else
      printf 'unknown\n'
    fi
  fi
}

# Copy the configured data files off the device into a fresh backup folder with SHA256SUMS, and check every copy
# against the device's own hash. Prints the backup folder.
qr_backup() {
  local dir f want got
  dir="$QR_BACKUP_ROOT/Quest-playtest-backup-$(qr_timestamp)${QR_BACKUP_DEVICE_SUFFIX:-}"
  [ -e "$dir" ] && dir="$dir-$$"
  # Backups may contain credentials; never expose them through default directory permissions.
  (umask 077; mkdir "$dir") || qr_die "cannot create private backup $dir"
  : > "$dir/SHA256SUMS" || qr_die "backup: cannot create checksum manifest"
  for f in $QR_DATA_FILES; do
    want="$(qr_device_sha "$f")"
    case "$want" in
      missing) qr_log "backup: $f is not on the device"; continue ;;
      unknown) qr_die "backup: cannot hash $f on the device" ;;
    esac
    qr_adb exec-out cat "$QR_DATA_DIR/$f" > "$dir/$f" 2>/dev/null || qr_die "backup: adb exec-out cat $f failed"
    got="$(qr_sha256 "$dir/$f")"
    [ "$got" = "$want" ] || qr_die "backup: $dir/$f does not match the device (local $got, device $want)"
    printf '%s  %s\n' "$got" "$f" >> "$dir/SHA256SUMS" || qr_die "backup: cannot record checksum for $f"
    qr_log "backup: $f copied and matched device hash ($got)"
  done
  # Recheck after every payload and manifest write, before installation can use this backup.
  while read -r want f; do
    got="$(qr_sha256 "$dir/$f")" || qr_die "backup: cannot hash completed backup file $f"
    [ "$got" = "$want" ] || qr_die "backup: completed backup checksum mismatch for $f"
  done < "$dir/SHA256SUMS"
  qr_log "backup: completed backup verified"
  printf '%s\n' "$dir"
}

qr_mic_state() {
  local g
  g="$(qr_adb_shell dumpsys package "$QR_PKG" | sed -n 's/.*android\.permission\.RECORD_AUDIO: granted=\([a-z]*\).*/\1/p' | head -n1)"
  printf '%s\n' "${g:-not requested}"
}

# install -r $1 with idle check, verified backup and before/after hashes of every configured data file.
# $2 = 1 for --force, $3 = label, $4 = extra flags (rollback: -d permits a lower versionCode).
qr_install_apk() {
  qr_device_locked qr_install_apk_locked "$@"
}

qr_install_apk_locked() {
  local apk="$1" force="$2" label="$3" flags="${4:-}" after dir out rc=0 f before_file
  # This attempt is the step's latest result even when the APK check stops it (any earlier success is stale).
  qr_set install "$label stopped before adb install (see release.log)"
  [ -f "$apk" ] || qr_die "$label: no APK at '$apk'"
  # Explicit APKs and rollbacks must pass the same launcher/signer gate as `all`.
  if [ "$apk" != "${QR_VERIFIED_APK:-}" ] && [ "$apk" != "${QR_VERIFIED_ROLLBACK_APK:-}" ]; then
    qr_java_setup || exit 1
    qr_verify "$apk" || exit 1
  fi
  qr_await_device
  qr_idle_check "$force"
  before_file="$QR_RUN_DIR/$label-data-before.txt"
  : > "$before_file"
  for f in $QR_DATA_FILES; do
    after="$(qr_device_sha "$f")"
    [ "$after" != unknown ] || qr_die "$label: cannot hash $f on the device"
    printf '%s %s\n' "$after" "$f" >> "$before_file"
  done
  dir="$(qr_backup)" || exit 1
  qr_set backup "$dir (verified against the device)"
  qr_log "$label: adb install -r${flags:+ $flags} $apk"
  # shellcheck disable=SC2086 # $flags is empty or -d
  out="$(qr_adb install -r $flags "$apk" 2>&1)" || rc=$?
  printf '%s\n' "$out" > "$QR_RUN_DIR/$label-adb.log"
  if [ "$rc" != 0 ] || ! printf '%s\n' "$out" | grep -q '^Success'; then
    qr_set install "$label FAILED: $(printf '%s\n' "$out" | tail -n1)"
    qr_die "$label: adb install -r${flags:+ $flags} failed: $(printf '%s\n' "$out" | tail -n1)"
  fi
  # adb has replaced the APK even if a later data check fails. Record its own commit, not this run's commit.
  qr_set installed_commit "$(qr_apk_commit "$apk")"
  qr_set installed_at "$(qr_timestamp)"
  qr_set install "$label: adb install ok ($apk), data checks not finished"
  local before
  while read -r before f; do
    after="$(qr_device_sha "$f")"
    [ "$after" != unknown ] || qr_die "$label: cannot hash $f after install; backup: $dir"
    if [ "$after" != "$before" ]; then
      qr_set data_hash "CHANGED: $f $before -> $after"
      qr_set install "$label ok ($apk), data CHANGED"
      qr_die "$label: $f changed during install ($before -> $after); backup: $dir"
    fi
  done < "$before_file"
  qr_set mic "RECORD_AUDIO granted=$(qr_mic_state)"
  qr_set data_hash "configured data files unchanged"
  qr_set install "$label ok ($apk)"
  qr_log "$label: ok; configured data unchanged; $(qr_get mic)"
}

qr_install() {
  local force=0 apk=""
  while [ $# -gt 0 ]; do
    case "$1" in --force) force=1 ;; *) apk="$1" ;; esac
    shift
  done
  [ -n "$apk" ] || apk="$(qr_get apk "")"
  qr_install_apk "$apk" "$force" install
}

qr_rollback() {
  local force=0 apk=""
  while [ $# -gt 0 ]; do
    case "$1" in --force) force=1 ;; *) apk="$1" ;; esac
    shift
  done
  [ -n "$apk" ] || qr_die "rollback: name the previous APK"
  qr_install_apk "$apk" "$force" rollback -d
}

# Shell broadcasts come from the shell's PID, not Unity's: do not use logcat --pid here. Match the complete package
# token on the same line, not a similarly named app or an unrelated line mentioning our package.
qr_launch_shell_lines() {
  grep -E 'appLaunchFailureBroadcastReceived|sendExtendedInterstitialBroadcast' "$@" \
    | grep -E "(^|[^[:alnum:]_.])${QR_PKG//./\\.}([^[:alnum:]_.]|$)" | sort -u
}

# Device-wide logcat stays available for diagnostics. Only the game's crashes may trigger rollback: associate
# threadtime/brief records with a PID observed after start or at the final check, or an AndroidRuntime Process:
# record naming the exact package (also catches a crash followed by a restart). Native tombstones name the package
# explicitly because their emitting PID belongs to debuggerd, not the app.
qr_launch_crashes() {
  awk -v package="$QR_PKG" -v pids="$2" -v crash_re="$QR_RE_CRASH" '
    function emitter(line, p) {
      if ($1 ~ /^[0-9][0-9]-/ && $3 ~ /^[0-9]+$/) return $3
      if (line ~ /^[VDIWEF]\/[^ (]+\( *[0-9]+\)/) {
        p=line; sub(/^[^(]*\( */, "", p); sub(/\).*/, "", p); return p
      }
      return ""
    }
    BEGIN { n=split(pids, ids, " "); for (i=1; i<=n; i++) if (ids[i] != "") own[ids[i]]=1 }
    NR == FNR {
      if ($0 ~ /AndroidRuntime[:( ]/ && index($0, "Process: " package ", PID: ")) {
        pid=emitter($0); if (pid != "") own[pid]=1
      }
      next
    }
    {
      pid=emitter($0)
      if (($0 ~ crash_re && pid in own) || ($0 ~ /F(\/|[[:space:]]+)DEBUG[: (]/ && index($0, ">>> " package " <<<"))) print
    }
  ' "$1" "$1"
}

# Keep the existing launch wait and crash policy, with one cheap shell check at 30 s (no polling). A shorter
# QUEST_LAUNCH_WAIT uses the final snapshot for the check. These broadcasts WARN only: never trigger rollback.
# Extract fps using a literal configured tag, never a regular expression from config.
qr_launch_fps() {
  [ -n "${QR_PERF_LOG_TAG:-}" ] || return 0
  grep -F -- "$QR_PERF_LOG_TAG" "$1" | grep -o 'fps=[0-9.]*' | tail -n1 | cut -d= -f2
}

# adb shell joins argv before remote execution. Quote each argument once for the
# remote POSIX shell so spaces and metacharacters remain data, not commands.
qr_start_activity() {
  local arg command="am start -n $QR_PKG/$QR_ACTIVITY"
  jq -e 'type == "array" and all(.[]; type == "string" and (test("[\u0000-\u001f]") | not))' \
    <<< "${QR_LAUNCH_ARGS:-[]}" >/dev/null || qr_die "quest.launchArgs must be a string array without control characters"
  set --
  while IFS= read -r -d '' arg; do set -- "$@" "$arg"; done \
    < <(jq -j '.[] | ., "\u0000"' <<< "${QR_LAUNCH_ARGS:-[]}")
  for arg in "$@"; do command="$command '${arg//\'/\'\\\'\'}'"; done
  qr_adb shell "$command"
}

qr_launch_infra() {
  qr_set launch "INFRA: $*"
  qr_log "launch: infrastructure: $*"
  exit "$QR_LAUNCH_INFRA"
}

# Keep remote pidof's status separate from adb's transport status. The trailer
# also detects truncated output or older shells that cannot execute the probe.
# Only status 1 with no PIDs confirms absence; malformed/failed probes fail closed.
qr_launch_pid() {
  local out status pids
  out="$(qr_adb shell "pidof '$QR_PKG'; qr_pid_rc=\$?; printf '\\nqr_pid_rc=%s\\n' \"\$qr_pid_rc\"" 2>/dev/null)" || return "$QR_LAUNCH_INFRA"
  out="${out//$'\r'/}"
  status="${out##*$'\n'qr_pid_rc=}"
  pids="${out%$'\n'qr_pid_rc=*}"
  pids="${pids%$'\n'}"
  case "$status" in
    0) [[ "$pids" =~ ^[0-9]+([[:space:]][0-9]+)*$ ]] || return "$QR_LAUNCH_INFRA" ;;
    1) [ -z "$pids" ] || return "$QR_LAUNCH_INFRA" ;;
    *) return "$QR_LAUNCH_INFRA" ;;
  esac
  printf '%s\n' "$pids"
}

qr_launch() (
  local rc=0
  # Replace stale success/crash even if the device lock refuses before launch.
  qr_set launch "INFRA: launch did not complete (device lock or setup failed; see release.log)"
  qr_device_locked qr_launch_locked "$@" || rc=$?
  case "$rc" in
    "$QR_LAUNCH_OK") return "$QR_LAUNCH_OK" ;;
    "$QR_LAUNCH_CRASH")
      case "$(qr_get launch)" in CRASH:*) return "$QR_LAUNCH_CRASH" ;; esac ;;
  esac
  return "$QR_LAUNCH_INFRA"
)

qr_launch_locked() {
  local cat="$QR_RUN_DIR/launch-logcat.txt" fps errs fatal alive=no pid start_pid findings crash=0 crashes
  local early="$QR_RUN_DIR/launch-early-logcat.txt" warnings="$QR_RUN_DIR/launch-shell-warnings.txt" shell_count=0
  ( qr_await_device ) || qr_launch_infra "device check/wait failed (see release.log)"
  qr_adb logcat -c || qr_launch_infra "adb logcat -c failed"
  ( qr_start_activity ) > "$QR_RUN_DIR/launch-am.log" 2>&1 \
    || qr_launch_infra "am start failed (launch-am.log)"
  # am can print a start/resolution error yet return 0 through adb shell.
  if grep -Eq '^[[:space:]]*(Error([[:space:]:]|$)|Exception([[:space:]:]|$)|[[:alnum:]_.$]+Exception:)' "$QR_RUN_DIR/launch-am.log"; then
    qr_launch_infra "am start reported an error (launch-am.log)"
  fi
  start_pid="$(qr_launch_pid)" || qr_launch_infra "initial pidof probe failed"
  qr_log "launch: started $QR_ACTIVITY; waiting ${QR_LAUNCH_WAIT}s"
  : > "$early"
  if [ "$QR_LAUNCH_WAIT" -gt 30 ]; then
    sleep 30
    if qr_adb logcat -d > "$early" 2>&1; then
      qr_launch_shell_lines "$early" > "$warnings"
      if [ -s "$warnings" ]; then
        qr_log "WARN: Quest shell still tracks a loading/launch failure for $QR_PKG (30s check; see launch-shell-warnings.txt)"
      fi
    else
      qr_launch_infra "early adb logcat -d failed"
    fi
    sleep "$((QR_LAUNCH_WAIT - 30))"
  else
    sleep "$QR_LAUNCH_WAIT"
  fi
  qr_adb logcat -d > "$cat" 2>&1 || qr_launch_infra "adb logcat -d failed"
  qr_launch_shell_lines -h "$early" "$cat" > "$warnings"
  shell_count="$(wc -l < "$warnings" | tr -d ' ')"
  pid="$(qr_launch_pid)" || qr_launch_infra "final pidof probe failed"
  [ -n "$pid" ] && alive=yes
  fps="$(qr_launch_fps "$cat")"
  errs="$(grep -cE "$QR_RE_UNITY_ERR" "$cat")"
  fatal="$(grep -cE "$QR_RE_FATAL" "$cat")"
  qr_launch_crashes "$cat" "$start_pid $pid" > "$QR_RUN_DIR/launch-game-crashes.txt"
  crashes="$(wc -l < "$QR_RUN_DIR/launch-game-crashes.txt" | tr -d ' ')"
  {
    echo "fps (configured tag): ${fps:-none}"
    echo "E/Unity lines ($errs):"; grep -E "$QR_RE_UNITY_ERR" "$cat" | head -n 10
    echo "FATAL/AndroidRuntime lines ($fatal):"; grep -E "$QR_RE_FATAL" "$cat" | head -n 20
    echo "process alive: $alive${pid:+ (pid $pid)}"
    if [ "$shell_count" != 0 ]; then
      echo "WARN: Quest shell still tracks a loading/launch failure for $QR_PKG ($shell_count broadcast lines; fps/alive do not prove launch completion)"
      head -n 10 "$warnings"
    fi
  } | tee "$QR_RUN_DIR/launch-report.txt"
  { [ "$crashes" != 0 ] || [ "$alive" = no ]; } && crash=1
  findings="fps ${fps:-none}, E/Unity $errs, fatal $fatal, alive $alive"
  [ "$shell_count" = 0 ] || findings="$findings, WARN shell launch warnings $shell_count"
  [ "$crash" = 1 ] && findings="CRASH: $findings"
  qr_set launch "$findings"
  [ "$crash" = 0 ] || return "$QR_LAUNCH_CRASH"
  return "$QR_LAUNCH_OK"
}
