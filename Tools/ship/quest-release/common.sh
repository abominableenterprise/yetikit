# shellcheck shell=bash
# Shared helpers for Tools/ship/quest-release.sh (docs/quest-release.md): logging, the run folder and its summary, state
# between subcommands, hashing, the time box and the Unity editor wrapper. Sourced; bash 3.2 (stock macOS) compatible.

# Resolve helpers from the executing kit, never from the consumer repository.
QR_SHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

qr_log() {
  printf '[quest-release] %s\n' "$*" >&2
  if [ -n "${QR_RUN_DIR:-}" ] && [ -d "$QR_RUN_DIR" ]; then
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$QR_RUN_DIR/release.log"
  fi
}

# Every subcommand runs in a subshell (qr_main), so this ends only that step.
qr_die() { qr_log "error: $*"; exit 1; }

# sha256 of a file ($1) or of stdin (no argument), lowercase hex only. shasum ships with macOS; sha256sum may not.
qr_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 ${1:+"$1"} | awk '{print $1}'
  else sha256sum ${1:+"$1"} | awk '{print $1}'; fi
}

qr_timestamp() { date '+%Y%m%d-%H%M%S'; }

# --- run folder, summary and state ---------------------------------------------------------------------------------------
# Summary values are one file per key under $QR_RUN_DIR/summary, so gate and build can set theirs in parallel.
qr_set() {
  [ -n "${QR_RUN_DIR:-}" ] || return 0
  mkdir -p "$QR_RUN_DIR/summary"
  printf '%s\n' "$2" > "$QR_RUN_DIR/summary/$1.tmp" && mv -f "$QR_RUN_DIR/summary/$1.tmp" "$QR_RUN_DIR/summary/$1"
}
qr_get() {
  if [ -n "${QR_RUN_DIR:-}" ] && [ -f "$QR_RUN_DIR/summary/$1" ]; then cat "$QR_RUN_DIR/summary/$1"; else printf '%s\n' "${2--}"; fi
}

# Step $1 passed: an earlier `all` in this run folder that skipped the install for it ("skipped: $1 failed", or
# "skipped: wrong debug keystore") must not keep saying so, as the summary shows each step's latest result. A later
# install or rollback writes its own result over "not run yet".
qr_step_ok() {
  case "$(qr_get install "")" in
    "skipped: $1 failed"*|"skipped: $1") qr_set install "not run yet ($1 ok)" ;;
  esac
}

qr_state_file() { printf '%s/current.env\n' "$QR_LOGS"; }

# Atomically publish a usable run identity. Prepare calls this only after both worktrees are ready.
qr_publish_state() {
  local f; f="$(qr_state_file)"
  printf 'QR_SHA=%q\nQR_REF=%q\nQR_SHORT=%q\nQR_RUN_DIR=%q\n' "$QR_SHA" "$QR_REF" "$QR_SHORT" "$QR_RUN_DIR" > "$f.tmp" \
    && mv -f "$f.tmp" "$f" || qr_die "cannot publish release state $f"
}

# Start a run folder for commit $1 (empty: manual), ref $2. $3=pending delays publishing until preparation succeeds.
qr_new_run() {
  QR_SHA="$1"; QR_REF="${2:-}"; QR_SHORT="${1:0:9}"
  QR_RUN_DIR="$QR_LOGS/${QR_SHORT:-manual}-$(qr_timestamp)"
  [ -e "$QR_RUN_DIR" ] && QR_RUN_DIR="$QR_RUN_DIR-$$"
  mkdir -p "$QR_RUN_DIR" || qr_die "cannot create the run folder $QR_RUN_DIR"
  [ "${3:-}" = pending ] || qr_publish_state
  export QR_SHA QR_REF QR_SHORT QR_RUN_DIR
}

# Load the current run (written by prepare); with none, start a manual run folder.
qr_load_state() {
  local f; f="$(qr_state_file)"
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    . "$f"
    export QR_SHA QR_REF QR_SHORT QR_RUN_DIR
    mkdir -p "$QR_RUN_DIR"
  else
    mkdir -p "$QR_LOGS" && qr_new_run "" ""
  fi
}

# The release worktree of kind $1 (test|build) for the current commit.
qr_wt() { printf '%s/rel-%s-%s\n' "$QR_ROOT" "$QR_SHORT" "$1"; }

qr_need_commit() { [ -n "${QR_SHA:-}" ] || qr_die "no prepared release: run 'Tools/ship/quest-release.sh prepare [<ref>]' first"; }

qr_summary() {
  local block
  block="$(cat <<EOF
==== Quest release summary ====
commit:      $(qr_get commit)
gate:        $(qr_get gate)
gate fails:  $(qr_get gate_failures)
notes:       $(qr_get notes)
apk:         $(qr_get apk)
apk sha256:  $(qr_get apk_sha256)
cert:        $(qr_get cert)
idle check:  $(qr_get idle)
backup:      $(qr_get backup)
install:     $(qr_get install)
data hash:   $(qr_get data_hash)
mic:         $(qr_get mic)
launch:      $(qr_get launch)
worktrees:   $(qr_get cleanup)
run folder:  ${QR_RUN_DIR:--}
===============================
EOF
)"
  printf '%s\n' "$block"
  if [ -n "${QR_RUN_DIR:-}" ] && [ -d "$QR_RUN_DIR" ]; then printf '%s\n' "$block" > "$QR_RUN_DIR/summary.txt"; fi
}

# --- time box ---------------------------------------------------------------------------------------------------------------
# Run "$@" for at most $1 seconds: gtimeout (coreutils) when present, else a background watchdog that sends
# TERM, then KILL 60 s later. A timeout returns 124 either way.
qr_timebox() {
  local secs="$1" pid w rc fired
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    # The release step already owns a cancellable process group; do not let timeout move the editor out of it.
    if [ "${QR_STEP_GROUP:-}" = 1 ]; then
      rc=0; gtimeout --foreground -k 60 "$secs" "$@" || rc=$?
    else
      rc=0; gtimeout -k 60 "$secs" "$@" || rc=$?
    fi
    [ "$rc" = 124 ] && qr_log "timed out after ${secs}s: ${1##*/}"
    return "$rc"
  fi
  fired="$(mktemp "${TMPDIR:-/tmp}/qr-timebox.XXXXXX")" && rm -f "$fired"
  "$@" &
  pid=$!
  (
    # On TERM (the run ended) stop every sleep this watchdog started, even one forked a moment before the signal.
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
    sleep "$secs" &
    wait
    if kill -0 "$pid" 2>/dev/null; then
      : > "$fired"; kill -TERM "$pid" 2>/dev/null
      sleep 60 &
      wait
      kill -KILL "$pid" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  w=$!
  rc=0; wait "$pid" || rc=$?
  kill -TERM "$w" 2>/dev/null; wait "$w" 2>/dev/null
  if [ -f "$fired" ]; then rm -f "$fired"; qr_log "timed out after ${secs}s: ${1##*/}"; return 124; fi
  return "$rc"
}

# --- Unity ------------------------------------------------------------------------------------------------------------------
# Use the validated config version; reject worktrees using a different editor.
qr_editor_dir() {
  local v
  v="$(sed -n 's/^m_EditorVersion:[[:space:]]*//p' "$1/ProjectSettings/ProjectVersion.txt" 2>/dev/null | tr -d '\r')"
  [ -n "${QR_UNITY_VERSION:-}" ] || { qr_log "unityVersion is required in config"; return 1; }
  [ "$v" = "$QR_UNITY_VERSION" ] || { qr_log "project editor '${v:-missing}' differs from configured unityVersion $QR_UNITY_VERSION"; return 1; }
  printf '%s/%s\n' "$UNITY_HUB_EDITORS" "$QR_UNITY_VERSION"
}

qr_unity_bin() {
  local d; d="$(qr_editor_dir "$1")" || return 1
  if [ -n "${UNITY_BIN:-}" ]; then printf '%s\n' "$UNITY_BIN"; return 0; fi
  printf '%s/Unity.app/Contents/MacOS/Unity\n' "$d"
}

# The Unity editor (tests replace this function): Unity args, the -projectPath picks the version. Time-boxed to
# $QR_UNITY_TIMEOUT seconds.
unity() {
  local proj="" prev="" a bin
  for a in "$@"; do [ "$prev" = -projectPath ] && proj="$a"; prev="$a"; done
  bin="$(qr_unity_bin "$proj")" || return 1
  [ -x "$bin" ] || { qr_log "no Unity editor at $bin"; return 1; }
  qr_timebox "${QR_UNITY_TIMEOUT:-1800}" "$bin" "$@"
}
