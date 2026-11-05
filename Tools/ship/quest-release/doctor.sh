# shellcheck shell=bash
# quest-release `doctor`: a read-only preflight in seconds, before a 25-minute `all`. One `ok` / `warn` / `FAIL` line
# per item; exits 1 when any item FAILs. It never prepares a worktree, writes a run folder, starts Unity, installs or
# changes the device (adb get-state, getprop and dumpsys only). Sourced by Tools/ship/quest-release.sh; bash 3.2.

qr_doctor_line() {
  printf '%-4s %-10s %s\n' "$1" "$2" "$3"
  [ "$1" != FAIL ] || QR_DOCTOR_FAILS=$((QR_DOCTOR_FAILS + 1))
}

# Unity editors working on a release worktree: "pid<TAB>project<TAB>log" per editor. -ww prevents BSD ps truncation.
# ps flattens argv, so take the executable up to the first option and path values up to the next option, not the next
# whitespace. This supports ordinary spaced Hub/worktree/log paths (and quoted values), without eval of process text.
# Like ps itself, this cannot disambiguate a path containing an option-looking component such as " -projectPath ".
qr_doctor_rel_editors() {
  ps -A -ww -o pid= -o args= 2>/dev/null | awk -v root="$QR_ROOT/rel-" '
    function unquote(s) {
      if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
          (substr(s, 1, 1) == "\047" && substr(s, length(s), 1) == "\047")) return substr(s, 2, length(s) - 2)
      return s
    }
    function path(args, option, value) {
      if (!match(args, "[[:space:]]" option "[[:space:]]+")) return ""
      value = substr(args, RSTART + RLENGTH)
      if (match(value, /[[:space:]]+-[[:alpha:]]/)) value = substr(value, 1, RSTART - 1)
      sub(/[[:space:]]+$/, "", value)
      return unquote(value)
    }
    { pid = $1; args = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", args)
      prog = args
      if (match(prog, /[[:space:]]+-/)) prog = substr(prog, 1, RSTART - 1)
      prog = unquote(prog)
      if (prog != "Unity" && prog !~ /^\/.*\/Unity$/) next
      proj = path(args, "-projectPath"); lf = path(args, "-logFile")
      if (index(proj, root) == 1) printf "%s\t%s\t%s\n", pid, proj, lf }'
}

qr_doctor_java() {
  if qr_java_setup 2>/dev/null; then
    qr_doctor_line ok java "JAVA_HOME=$JAVA_HOME ($QR_JAVA_SRC)"; return 0
  fi
  qr_doctor_line FAIL java "no runnable JDK: JAVA_HOME is unset or broken and no Unity editor under $UNITY_HUB_EDITORS has PlaybackEngines/AndroidPlayer/OpenJDK"
  return 1
}

qr_doctor_apksigner() {
  local java_ok="$1" bin ver
  qr_android_sdk 2>/dev/null || { qr_doctor_line FAIL apksigner "no Android SDK (set ANDROID_SDK_ROOT)"; return; }
  bin="$(qr_apksigner_path)" || { qr_doctor_line FAIL apksigner "no apksigner in the newest build-tools under $ANDROID_SDK_ROOT/build-tools"; return; }
  [ "$java_ok" = 1 ] || { qr_doctor_line FAIL apksigner "$bin needs Java (see java)"; return; }
  if ver="$("$bin" --version 2>/dev/null </dev/null)" && [ -n "$ver" ]; then
    # Inspect the exit status before trimming output: a pipeline to head masks an apksigner failure without pipefail.
    ver="${ver%%$'\n'*}"
    qr_doctor_line ok apksigner "$bin ($ver)"
  else
    qr_doctor_line FAIL apksigner "$bin --version does not run with JAVA_HOME=$JAVA_HOME"
  fi
}

qr_doctor_keystore() {
  local ks got rc=0 want xks
  if ! (qr_require_certificate) 2>/dev/null; then
    qr_doctor_line FAIL keystore "QUEST_CERT_SHA256 must supply the expected signer SHA-256 (64 hex digits)"
    return 1
  fi
  ks="$(qr_android_user_home)/debug.keystore"
  want="$(qr_norm_hex "$QR_CERT_SHA256")"
  got="$(qr_keystore_check "$ks" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) qr_doctor_line ok keystore "$ks matches the expected certificate (${got:0:16}...)" ;;
    1) qr_doctor_line FAIL keystore "$ks has certificate ${got:0:16}..., expected ${want:0:16}... (set ANDROID_USER_HOME to the folder with the right debug.keystore)" ;;
    2) qr_doctor_line warn keystore "no $ks yet (Gradle creates it; verify checks the APK signer)" ;;
    3) qr_doctor_line warn keystore "$ks not checked: no keytool on PATH" ;;
    *) qr_doctor_line warn keystore "$ks not checked: keytool could not read it" ;;
  esac
  # The build drops XDG_CONFIG_HOME, but a Unity or Gradle run by hand from this shell signs with this key (for manual builds).
  [ -n "${XDG_CONFIG_HOME:-}" ] || return 0
  xks="$XDG_CONFIG_HOME/.android/debug.keystore"
  [ "$xks" != "$ks" ] && [ -f "$xks" ] || return 0
  rc=0; got="$(qr_keystore_check "$xks" 2>/dev/null)" || rc=$?
  [ "$rc" = 1 ] && qr_doctor_line warn keystore "XDG_CONFIG_HOME is set and $xks has another certificate (${got:0:16}...): the build ignores it, but a Unity or Gradle started by hand from this shell would sign with it"
  return 0
}

qr_doctor_unity() {
  local bin
  if ! bin="$(qr_unity_bin "$QR_REPO" 2>/dev/null)"; then
    qr_doctor_line FAIL unity "project editor version is missing or differs from unityVersion $QR_UNITY_VERSION"
  elif [ -x "$bin" ]; then qr_doctor_line ok unity "$bin"
  else qr_doctor_line FAIL unity "no Unity editor at $bin"; fi
}

qr_doctor_disk() {
  local dir="$QR_ROOT" free
  while [ ! -d "$dir" ] && [ "$dir" != / ] && [ -n "$dir" ]; do dir="$(dirname "$dir")"; done
  free="$(qr_free_gb "$dir" 2>/dev/null)"
  case "$free" in
    ''|*[!0-9]*) qr_doctor_line FAIL disk "cannot read free space for $dir from df" ;;
    *) if [ "$free" -ge "$QR_MIN_FREE_GB" ]; then qr_doctor_line ok disk "$free GB free on $dir (need $QR_MIN_FREE_GB)"
       else qr_doctor_line FAIL disk "only $free GB free on $dir; prepare needs $QR_MIN_FREE_GB (QUEST_MIN_FREE_GB)"; fi ;;
  esac
}

qr_doctor_device() {
  local why verdict rc=0
  command -v adb >/dev/null 2>&1 || { qr_doctor_line FAIL device "no adb on PATH"; qr_doctor_line warn idle "not checked (no device)"; return; }
  if ! why="$(qr_device_status)"; then qr_doctor_line FAIL device "$why"; qr_doctor_line warn idle "not checked (no device)"; return; fi
  qr_doctor_line ok device "$why"
  verdict="$(qr_idle_verdict)" || rc=$?
  case "$rc" in
    0) qr_doctor_line ok idle "idle ($verdict)" ;;
    1) qr_doctor_line warn idle "in use ($verdict): install would refuse without --force" ;;
    *) qr_doctor_line warn idle "unknown ($verdict): install would refuse, even with --force" ;;
  esac
}

qr_doctor_running() {
  local st=0 eds pid proj log
  qr_lock_read || st=$?
  case "$st" in
    0) qr_doctor_line FAIL running "another quest-release run is active (pid $QR_LOCK_PID, run folder $QR_LOCK_RUN)"; return ;;
    2) qr_doctor_line warn running "stale lock $(qr_lock_dir) (pid $QR_LOCK_PID is gone, run folder $QR_LOCK_RUN): the next run removes it" ;;
  esac
  eds="$(qr_doctor_rel_editors)"
  if [ -n "$eds" ]; then
    while IFS="$(printf '\t')" read -r pid proj log; do
      qr_doctor_line FAIL running "a Unity editor is running on $proj (pid $pid, run folder $(dirname "${log:-?}"))"
    done <<EOF
$eds
EOF
  elif [ "$st" = 1 ]; then
    qr_doctor_line ok running "no other quest-release run or Unity editor on $QR_ROOT/rel-*"
  fi
}

qr_doctor() {
  local java_ok=0
  QR_DOCTOR_FAILS=0
  echo "==== Quest release doctor (read-only) ===="
  qr_doctor_java && java_ok=1
  qr_doctor_apksigner "$java_ok"
  qr_doctor_keystore
  qr_doctor_unity
  qr_doctor_disk
  qr_doctor_device
  qr_doctor_running
  if [ "$QR_DOCTOR_FAILS" != 0 ]; then echo "doctor: $QR_DOCTOR_FAILS FAIL"; return 1; fi
  echo "doctor: no FAIL"
}
