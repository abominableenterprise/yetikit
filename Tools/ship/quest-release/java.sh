# shellcheck shell=bash
# quest-release's JDK: apksigner (verify) and keytool (the keystore preflight) need Java, and macOS's /usr/bin/java is
# only a stub ("Unable to locate a Java Runtime."). Sourced by Tools/ship/quest-release.sh; bash 3.2 compatible.

# 0 when $1 is a JDK home whose bin/java actually runs.
qr_java_ok() { [ -n "$1" ] && [ -x "$1/bin/java" ] && "$1/bin/java" -version >/dev/null 2>&1; }

# Hub macOS modules live inside the app bundle; also accept modules installed directly in the version directory.
# Prefer bundled modules when both exist. Shared with SDK discovery in verify.sh; never executes the editor.
qr_unity_contents() {
  if [ -d "$1/Unity.app/Contents/PlaybackEngines" ] ||
     { [ -d "$1/Unity.app/Contents" ] && [ ! -d "$1/PlaybackEngines" ]; }; then
    printf '%s/Unity.app/Contents\n' "$1"
  else printf '%s\n' "$1"; fi
}

# Unity's bundled OpenJDK: the project's editor (ProjectVersion.txt) first, else the last installed editor that has one.
qr_unity_jdk() {
  local d jdk best=""
  if d="$(qr_editor_dir "$QR_REPO" 2>/dev/null)"; then
    jdk="$(qr_unity_contents "$d")/PlaybackEngines/AndroidPlayer/OpenJDK"
    if qr_java_ok "$jdk"; then printf '%s\n' "$jdk"; return 0; fi
  fi
  for d in "$UNITY_HUB_EDITORS"/*; do
    jdk="$(qr_unity_contents "$d")/PlaybackEngines/AndroidPlayer/OpenJDK"
    qr_java_ok "$jdk" && best="$jdk"
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Keep a working JAVA_HOME, else use Unity's OpenJDK; export it with its bin first on PATH. Returns 1 when there is none,
# so `all`, `build` and `verify` stop before any work instead of failing at verify.
qr_java_setup() {
  local jdk src="JAVA_HOME"
  if ! qr_java_ok "${JAVA_HOME:-}"; then
    [ -z "${JAVA_HOME:-}" ] || qr_log "java: JAVA_HOME=$JAVA_HOME has no runnable bin/java; looking for Unity's OpenJDK"
    if ! jdk="$(qr_unity_jdk)"; then
      qr_log "error: no Java runtime: JAVA_HOME is unset or broken and no Unity editor under $UNITY_HUB_EDITORS has PlaybackEngines/AndroidPlayer/OpenJDK (install Android Build Support with OpenJDK, or set JAVA_HOME); apksigner and keytool need it"
      return 1
    fi
    JAVA_HOME="$jdk"; src="Unity's bundled OpenJDK"
  fi
  # shellcheck disable=SC2034 # doctor.sh reports it
  QR_JAVA_SRC="$src"
  export JAVA_HOME
  PATH="$JAVA_HOME/bin:$PATH"
  export PATH
  qr_log "java: JAVA_HOME=$JAVA_HOME ($src)"
}
