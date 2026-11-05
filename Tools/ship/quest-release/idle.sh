# shellcheck shell=bash
# quest-release's idle check before `install` / `rollback`: is someone wearing the headset and using an app? Sourced by
# Tools/ship/quest-release.sh; bash 3.2 (stock macOS) compatible. qr_idle_parse is pure (dumpsys text on stdin) for tests.

# The Quest Home / launcher packages (a focused Home is never "in use").
QR_HOME_PKGS="com.oculus.vrshell com.oculus.vrshell.home com.oculus.shellenv"

# stdin: `dumpsys activity activities`, `dumpsys window windows`, `dumpsys power` and `dumpsys vrpowermanager` text.
# The focus comes from ResumedActivity, topDisplayFocusedRootTask and WindowManager's mCurrentFocus / mFocusedApp, never
# topResumedActivity (Quest lists one per system panel) or a task's mResumedActivity (a panel behind the shell).
# Worn: $1 = `getprop sys.hmt.mounted` decides first when it is a clean 0 (not worn) or 1 (worn). Missing or anything
# else: vrpowermanager's current state, the first `State:` / `Headset state:` line naming HEADSET_MOUNTED (worn),
# HEADSET_UNMOUNTED or STANDBY (not worn; history and transition lines never count), else Display Power state, else
# mWakefulness. A focused Home is idle whatever the headset says.
# Prints the reason; exits 0 idle (Home focused, or not worn), 1 busy (worn and a non-Home app focused), 2 unknown.
qr_idle_parse() {
  local hmt="${1:-}" line pkg n=0 other="" vr_state="" on=0 off=0 awake=0 asleep=0 worn
  local re_state='^[[:space:]]*(Headset[[:space:]]+[Ss]tate|State):[[:space:]]*(HEADSET_MOUNTED|HEADSET_UNMOUNTED|STANDBY)[[:space:]]*$'
  local re_rec='^[[:space:]]*(ResumedActivity:|mCurrentFocus=|mFocusedApp=)[[:space:]]*(ActivityRecord|Window)\{[^}]*[[:space:]]u[0-9]+[[:space:]]+([^}/[:space:]]+)'
  local re_task='^[[:space:]]*topDisplayFocusedRootTask=Task\{([^}]*)\}'
  while IFS= read -r line; do
    line="${line%$'\r'}"
    pkg=""
    if [[ "$line" =~ $re_rec ]]; then
      pkg="${BASH_REMATCH[3]}"
    elif [[ "$line" =~ $re_task ]]; then
      line=" ${BASH_REMATCH[1]} "
      if [[ "$line" == *" type=home "* ]]; then pkg=com.oculus.vrshell
      elif [[ "$line" =~ [[:space:]]A=([0-9]+:)?([[:alnum:]_.]+) ]]; then pkg="${BASH_REMATCH[2]}"
      else pkg="?"; fi
    else
      if [[ "$line" =~ $re_state ]]; then
        [ -n "$vr_state" ] || vr_state="${BASH_REMATCH[2]}"
      elif [[ "$line" =~ ^[[:space:]]*Display[[:space:]]Power:[[:space:]]state=([A-Z_]+)[[:space:]]*$ ]]; then
        case "${BASH_REMATCH[1]}" in ON) on=1 ;; OFF|DOZE|DOZE_SUSPEND) off=1 ;; esac
      elif [[ "$line" =~ ^[[:space:]]*mWakefulness=([A-Za-z]+)[[:space:]]*$ ]]; then
        case "${BASH_REMATCH[1]}" in Awake) awake=1 ;; Asleep|Dozing) asleep=1 ;; esac
      fi
    fi
    [ -n "$pkg" ] || continue
    n=$((n + 1))
    case " $QR_HOME_PKGS " in *" $pkg "*) continue ;; esac
    case " $other " in *" $pkg "*) ;; *) other="${other:+$other }$pkg" ;; esac
  done
  [ "$n" != 0 ] || { echo "no focused app (ResumedActivity, topDisplayFocusedRootTask, mCurrentFocus, mFocusedApp)"; return 2; }
  [ -n "$other" ] || { echo "Home focused"; return 0; }
  # The proximity sensor's sys.hmt.mounted decides when clean; then the current headset state, the display, wakefulness.
  if [ "$hmt" = 0 ]; then worn="no sys.hmt.mounted=0"
  elif [ "$hmt" = 1 ]; then worn="yes sys.hmt.mounted=1"
  elif [ "$vr_state" = HEADSET_MOUNTED ]; then worn="yes $vr_state"
  elif [ -n "$vr_state" ]; then worn="no $vr_state"
  elif [ "$on" = 1 ] && [ "$off" = 0 ]; then worn="yes display on"
  elif [ "$off" = 1 ] && [ "$on" = 0 ]; then worn="no display off"
  elif [ "$on" = 1 ]; then echo "conflicting Display Power states; focused: $other"; return 2
  elif [ "$awake" = 1 ] && [ "$asleep" = 0 ]; then worn="yes awake"
  elif [ "$asleep" = 1 ] && [ "$awake" = 0 ]; then worn="no asleep"
  else echo "cannot tell whether the headset is worn; focused: $other"; return 2
  fi
  case "$worn" in
    no*) echo "not worn (${worn#no }), focused: $other"; return 0 ;;
    *) echo "worn (${worn#yes }), focused: $other"; return 1 ;;
  esac
}

# Gather the dumpsys text and getprop sys.hmt.mounted, print qr_idle_parse's verdict and return its code (0 idle,
# 1 busy, 2 unknown); 3 with the reason when adb cannot give the focus or power state. Never changes the device.
qr_idle_verdict() {
  local acts win power vr hmt
  acts="$(qr_adb shell dumpsys activity activities 2>/dev/null)" \
    || { echo "cannot determine the focused app (dumpsys activity failed)"; return 3; }
  printf '%s\n' "$acts" | grep -Eq '^[[:space:]]*(ResumedActivity:|topDisplayFocusedRootTask=)' \
    || { echo "cannot determine the focused app (no ResumedActivity or topDisplayFocusedRootTask)"; return 3; }
  win="$(qr_adb shell dumpsys window windows 2>/dev/null)" \
    || { echo "cannot determine the focused window (dumpsys window failed)"; return 3; }
  power="$(qr_adb shell dumpsys power 2>/dev/null)" \
    || { echo "cannot determine display power (dumpsys power failed)"; return 3; }
  vr="$(qr_adb shell dumpsys vrpowermanager 2>/dev/null)" || vr="" # Quest only; optional
  # Check adb before stripping CR: qr_adb_shell's pipeline can mask a failed query that printed a stale 0.
  hmt="$(qr_adb shell getprop sys.hmt.mounted 2>/dev/null)" || hmt="" # optional; a clean 0 or 1 decides
  hmt="${hmt//$'\r'/}"
  printf '%s\n' "$acts" "$win" "$power" "$vr" | qr_idle_parse "$hmt"
}

# Refuse to install while someone uses the headset (--force: $1 = 1 overrides only a known "busy", never an unknown).
qr_idle_check() {
  local force="$1" verdict rc=0
  verdict="$(qr_idle_verdict)" || rc=$?
  case "$rc" in
    0) qr_set idle "idle ($verdict)"; qr_log "idle check: idle ($verdict)" ;;
    1)
      if [ "$force" = 1 ]; then
        qr_set idle "IN USE ($verdict), --force given"
        qr_log "headset in use ($verdict); continuing because of --force"
        return 0
      fi
      qr_set idle "IN USE ($verdict): refused"
      qr_die "headset in use ($verdict); retry later or pass --force" ;;
    3) qr_die "idle check: $verdict" ;;
    *)
      qr_set idle "unknown ($verdict): refused"
      qr_die "idle check: cannot determine whether the headset is in use: $verdict" ;;
  esac
}
