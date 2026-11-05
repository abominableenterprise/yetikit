# shellcheck shell=bash
# Schema validation shared with Linux; scalar reads keep this entry point Bash 3.2 compatible.
qr_config_get() { printf '%s\n' "$QR_CONFIG_JSON" | jq -r "$1"; }

qr_positive_seconds() {
  case "$2" in ''|*[!0-9]*|0*) qr_log "error: $1 must be a positive integer"; return 1 ;; esac
  [ "${#2}" -le 7 ] || { qr_log "error: $1 is too large"; return 1; }
}

qr_config() {
  QR_REPO="${PROJECT:-${QUEST_REPO:-$(cd "$QR_DIR/../.." && pwd)}}"
  QR_REPO="$(cd "$QR_REPO" && pwd)" || return 1
  QR_CONFIG_FILE="${YETIKIT_CONFIG:-$QR_REPO/yetikit.json}"
  case "$QR_CONFIG_FILE" in /*) ;; *) QR_CONFIG_FILE="$PWD/$QR_CONFIG_FILE" ;; esac
  command -v jq >/dev/null 2>&1 || { qr_log 'error: jq is required'; return 1; }
  [ -f "$QR_CONFIG_FILE" ] || { qr_log "error: missing config $QR_CONFIG_FILE"; return 1; }
  local error root key value
  error="$(jq -sr -f "$QR_DIR/lib/config.jq" "$QR_CONFIG_FILE")" || return 1
  [ -z "$error" ] || { qr_log "error: $error"; return 1; }
  QR_CONFIG_JSON="$(jq -f "$QR_DIR/lib/config-paths.jq" "$QR_CONFIG_FILE")" || return 1
  [ "$(qr_config_get 'has("quest")')" = true ] || { qr_log 'error: missing quest config block'; return 1; }
  QR_UNITY_VERSION="$(qr_config_get '.unityVersion')"
  QR_PKG="$(qr_config_get '.quest.package')"
  QR_ACTIVITY=com.unity3d.player.UnityPlayerGameActivity
  QR_DATA_DIR="/sdcard/Android/data/$QR_PKG/files"
  QR_DATA_FILES="$(qr_config_get '(.quest.dataFiles // ["playtest.json", "throws.csv"]) | join(" ")')"
  QR_BUILD_METHOD="$(qr_config_get '.build.devMethod')"
  QR_APK_REL="$(qr_config_get '.build.apkPath')"
  QR_APK_KEEP_NAME="$(qr_config_get '.quest.apkKeepName // "game-dev-{sha}.apk"')"
  QR_PERF_LOG_TAG="$(qr_config_get '.quest.perfLogTag // empty')"
  QR_WHATS_NEW_ENV="$(qr_config_get '.quest.whatsNewEnv // "YETIKIT_WHATS_NEW"')"
  QR_PREV_SHA_ENV="$(qr_config_get '.quest.prevShaEnv // "YETIKIT_PREV_SHA"')"
  QR_LAUNCH_ARGS="$(qr_config_get '.quest.launchArgs // []')"
  root="$(qr_config_get '.quest.worktreeRoot // empty')"
  root="${root:-$HOME/wt/${QR_REPO##*/}}"
  # Expand only a leading home marker; never eval project configuration.
  case "$root" in '~/'*) root="$HOME/${root#\~/}" ;; '$HOME/'*) root="$HOME/${root#\$HOME/}" ;; /*) ;; *) root="$QR_REPO/$root" ;; esac
  QR_ROOT="${QUEST_WT_ROOT:-$root}"
  QR_WARM="${QUEST_WARM_WORKTREE:-$QR_ROOT/mac-pass}"
  QR_LOGS="${QUEST_LOG_ROOT:-$QR_ROOT/release-logs}"
  QR_APK_DIR="${QUEST_APK_DIR:-$QR_WARM/$(dirname "$QR_APK_REL")}"
  QR_MIN_FREE_GB="${QUEST_MIN_FREE_GB:-25}"
  QR_CERT_SHA256="${QUEST_CERT_SHA256:-}"
  QUEST_SERIAL="${QUEST_SERIAL:-}"
  QR_BACKUP_ROOT="${QUEST_BACKUP_ROOT:-$HOME}"
  QR_LAUNCH_WAIT="${QR_LAUNCH_WAIT:-${QUEST_LAUNCH_WAIT:-60}}"
  QR_ADB_WAIT="${QR_ADB_WAIT:-${QUEST_ADB_WAIT:-120}}"
  QR_GATE_TIMEOUT="${QR_GATE_TIMEOUT:-${QUEST_GATE_TIMEOUT:-1800}}"
  QR_BUILD_TIMEOUT="${QR_BUILD_TIMEOUT:-${QUEST_BUILD_TIMEOUT:-1800}}"
  QR_KNOWN_FLAKES="${QUEST_KNOWN_FLAKES:-$(qr_config_get '.knownFlakes // empty')}"
  case "$QR_KNOWN_FLAKES" in ''|/*) ;; *) QR_KNOWN_FLAKES="$QR_REPO/$QR_KNOWN_FLAKES" ;; esac
  UNITY_HUB_EDITORS="${UNITY_HUB_EDITORS:-/Applications/Unity/Hub/Editor}"
  for key in QR_LAUNCH_WAIT QR_ADB_WAIT QR_GATE_TIMEOUT QR_BUILD_TIMEOUT QR_MIN_FREE_GB; do
    value="${!key}"
    qr_positive_seconds "$key" "$value" || return 1
  done
}

# Read-only discovery; never choose an arbitrary headset or persist its serial.
qr_select_device() {
  [ -z "$QUEST_SERIAL" ] || return 0
  local devices count
  devices="$(adb devices 2>/dev/null | awk 'NR > 1 && NF >= 2 {print $1}')" || return 1
  count="$(printf '%s\n' "$devices" | awk 'NF {n++} END {print n+0}')"
  [ "$count" = 1 ] || { qr_log "error: found $count attached devices; set QUEST_SERIAL explicitly (expected one)"; return 1; }
  QUEST_SERIAL="$devices"
}
