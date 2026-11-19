#!/usr/bin/env bash
# Run the Unity editor headless on a Linux VM (no Docker): see README.md.
#
#   setup [--no-creds] [--android]  editor + libraries; --no-creds caches without credentials. --android installs
#                       the GameCI android image instead (editor + Android SDK/NDK/OpenJDK) and replaces a base
#                       editor without the Android module
#   apk [dev|release|contest]   build the configured Android APK on Xvfb;
#                       log in build/apk.log; prints the APK path, size and sha256. Needs setup --android. Library
#                       cache: its own Android key (cache-key android), restored when Library/ is missing. Fails early
#                       under APK_MIN_FREE_GB (10; warm Library/Bee/Android: APK_MIN_FREE_GB_WARM, 4) free; caps IL2CPP/bee at APK_JOBS (2) parallel jobs; on a VM under
#                       12 GB RAM without swap adds an APK_SWAP_GB (3) swapfile, removed on exit
#   activate            activate a Unity Personal ULF licence (needs UNITY_USERNAME/UNITY_PASSWORD); an existing
#                       Unity_lic.ulf is validated first and an invalid one is moved aside and re-activated
#   return              return the ULF licence (needs UNITY_USERNAME/UNITY_PASSWORD)
#   open [--keep [<path>]]...
#                       open/compile the project (after the same stale-editor cleanup as test); a cold open
#                       (no Library/) runs cache-restore first and cache-save after it succeeds. Then reverts the run's
#                       noise (*.mat diffs of only _ZTest lines, *.prefab diffs of only float formatting) in files
#                       that were clean before; --keep <path> protects a path, a bare --keep skips the revert
#   cache-restore       task-cache restore <key> Library (no-op without task-cache); key: see cache_key. Gives up
#                       after TASK_CACHE_TIMEOUT seconds (default 300), or on a miss/error, and leaves no Library/
#   cache-save          task-cache save <key> Library (no-op without task-cache)
#   cache-key           print the Library cache key (bare 64-hex sha256)
#   scene [--keep <path>]... [--area <Area>]...
#                       run configured scene steps, then revert bake-only and editor noise
#   lab                 run the optional configured lab method on Xvfb
#   test editmode|playmode [extra Unity args...]
#                       editmode runs the pure tests with -nographics (-testCategory "!Gfx;!MacOnly"), then the
#                       [Category("Gfx")] tests on Xvfb + Mesa llvmpipe. EDITMODE_GFX=0 skips the second pass.
#                       A caller's -testFilter runs in both passes: either may select zero tests with valid XML,
#                       but together they must execute tests. EDITMODE_GFX=0 still requires a nonempty pure pass.
#                       A caller's -testCategory runs one nonempty pass on Xvfb. -assemblyNames narrows
#                       both default passes but leaves Gfx optional; the pure pass still must execute tests.
#                       A -testFilter naming a [Category("RenderTool")] class runs one pass on
#                       Xvfb with -testCategory RenderTool. Every Gfx run (this second pass, a -testCategory naming
#                       Gfx, test pr's Gfx pass) is killed after UNITY_GFX_TIMEOUT s (3600), the others after
#                       UNITY_TIMEOUT s (1800); a caller's UNITY_TIMEOUT alone sets both.
#   test pr [base] [extra Unity args...]
#                       the full pure pass (opt-in selection via tests.prPure), then Gfx for fixtures declared in test
#                       files changed since `git merge-base base HEAD` (base: origin/main) or in the EditMode test
#                       folder referencing a changed <tests.scriptsRoot>/<Area>/<Class>.cs (max TEST_PR_GFX_MAX, 12).
#                       No matching fixture skips Gfx. Stage timings: build/test-stages.log.
#                       Every test command: when all failures of a pass are in the configured known-flakes file, they rerun
#                       once (<pass>-retry.xml) and a green rerun passes. The noise revert and --keep work as in open.
#   stop                stop the recorded run (including setup) and its workers (pidfile $OUT_DIR/linux-unity.pid)
#   all                 setup, activate, open, test editmode (keeps the licence, including on failure)
#
# A successful editor command with failed noise cleanup exits 3; rerun only the printed scene-noise command.
# Credentials are read from the environment only and are never printed: UNITY_USERNAME/UNITY_PASSWORD, or, when
# either is unset or empty, USERNAME/PASSWORD (the hub's 1Password login fields) if both are set.
# Licences/seats stay held between commands; UNITY_IDLE_RETURN_MINUTES (10) idle returns them.
# UNITY_RETURN_ON_EXIT=1 returns on exit, even on failure; a failed return alone makes the command fail.
# Do not run this with `set -x` or `bash -x`.
set -euo pipefail

PROJECT="${PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
ship_config_load || { return 1 2>/dev/null || exit 1; }
SHIP_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIP_COMMAND="${SHIP_TOOL_DIR#"$PROJECT"/}/linux-unity.sh"
SHIP_NOISE_COMMAND="${SHIP_TOOL_DIR#"$PROJECT"/}/scene-noise.sh"
UNITY_VERSION="$(ship_config_get '.unityVersion')"
UNITY_MODULES="${UNITY_MODULES:-}"
UNITY_IMAGE_BASE="unityci/editor:ubuntu-${UNITY_VERSION}-base-3"
UNITY_IMAGE_ANDROID="unityci/editor:ubuntu-${UNITY_VERSION}-android-3"
# Android player module (with its SDK, NDK and OpenJDK, which the GameCI android image puts inside it).
ANDROID_REL="Editor/Data/PlaybackEngines/AndroidPlayer"
# Seconds per APK build (a cold IL2CPP build takes ~40 min on 4 vCPU).
APK_TIMEOUT="${APK_TIMEOUT:-5400}"
# Parallel IL2CPP conversion/C++ compile jobs (il2cpp --jobs, bee BEE_BUILD_THREADS): each clang++ of the generated C++
# can take 1-2 GB, so the default 2 keeps an 8 GB VM out of the OOM killer. 0 leaves Unity's default (one per core).
APK_JOBS="${APK_JOBS:-2}"
# apk checks free disk both before and after cache restore: a cold build (no Library/Bee/Android) writes
# ~9 GB (IL2CPP intermediates, Gradle project, APK + symbols); a warm rebuild reuses them (APK_MIN_FREE_GB_WARM).
APK_MIN_FREE_GB="${APK_MIN_FREE_GB:-10}"
APK_MIN_FREE_GB_WARM="${APK_MIN_FREE_GB_WARM:-4}"
# Swapfile (GB) apk adds for the build when the VM has less than APK_SWAP_BELOW_GB of RAM and no swap; 0 = none.
# It lives in APK_SWAP_DIR (swapon fails on an overlay root; /.fly-upper-layer is the disk under it) and is removed
# when apk exits, however it exits.
APK_SWAP_GB="${APK_SWAP_GB:-3}"
APK_SWAP_BELOW_GB="${APK_SWAP_BELOW_GB:-12}"
APK_SWAP_DIR="${APK_SWAP_DIR:-$([ -d /.fly-upper-layer ] && echo /.fly-upper-layer || echo /var/tmp)}"
# Match /proc's canonical executable paths, including aliases and not-yet-created install roots.
UNITY_ROOT="$(realpath -m -- "${UNITY_ROOT:-/opt/unity}")"
BIN_REL="Editor/Unity"
LC_REL="Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client"
UNITY_BIN="$UNITY_ROOT/$BIN_REL"
LC="$UNITY_ROOT/$LC_REL"
CRANE_VERSION="${CRANE_VERSION:-v0.22.1}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
OUT_DIR="${OUT_DIR:-$PROJECT/build}"
ULF="${ULF:-$HOME/.local/share/unity3d/Unity/Unity_lic.ulf}"
SHM_DIR="${SHM_DIR:-/dev/shm}"
# Seconds per editor run (open, scene, the pure pass). The Gfx pass (every run of the Gfx category: test editmode's
# second pass, a caller's -testCategory naming Gfx, test pr's Gfx pass) gets UNITY_GFX_TIMEOUT instead: 3600 by
# default (112 Gfx tests took 1,872 s on a 4 vCPU llvmpipe VM on 2026-11-01). A caller's UNITY_GFX_TIMEOUT wins,
# then a caller's UNITY_TIMEOUT, so an explicit UNITY_TIMEOUT still sets every pass.
TEST_PR_TIMEOUT_EXPLICIT="${UNITY_GFX_TIMEOUT:-${UNITY_TIMEOUT:-}}"
UNITY_GFX_TIMEOUT="${UNITY_GFX_TIMEOUT:-${UNITY_TIMEOUT:-3600}}"
UNITY_TIMEOUT="${UNITY_TIMEOUT:-1800}"
TASK_CACHE="${TASK_CACHE:-task-cache}"
# Seconds a cache restore may take before it is abandoned for a cold import (a slow R2 edge once ran at 60 KB/s).
TASK_CACHE_TIMEOUT="${TASK_CACHE_TIMEOUT:-300}"
# Test categories (NUnit [Category], on the class): "Gfx" tests enter Play Mode or render. With -nographics they
# segfault the editor (RenderTexture.Create failed, signal 11), so they run in a separate pass with a GL device.
# "MacOnly" tests are too slow on llvmpipe or frame-rate sensitive, so Linux skips them. TestPassCategoryTests fails
# when a [UnityTest] class has neither (nor the "PureUnityTest" opt-out). Exclusion uses the Test Framework's '!'.
PURE_CATEGORIES='!Gfx;!MacOnly'
GFX_CATEGORIES='Gfx'
KNOWN_FLAKES="${KNOWN_FLAKES:-$PROJECT/$(ship_config_get '.knownFlakes // ""')}"
SCENE_AREAS="${SCENE_AREAS:-$PROJECT/$(ship_config_get '.scene.areasFile // ""')}"
# The editor runs this script launched (xvfb-run, so Xvfb and the editor are its children): `stop` kills them.
PIDFILE="${PIDFILE:-$OUT_DIR/linux-unity.pid}"
PIDFILE_FALLBACK="${PIDFILE_FALLBACK:-/tmp/linux-unity-$(id -u).pid}"

log() { printf '[linux-unity] %s\n' "$*" >&2; }
# shellcheck source=Tools/ship/scene-noise.sh
. "$(dirname "${BASH_SOURCE[0]}")/scene-noise.sh"
# shellcheck source=Tools/ship/test-passes.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-passes.sh"
. "$SHIP_TOOL_DIR/test-pr-pure.sh"
# shellcheck source=Tools/ship/test-evidence.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-evidence.sh"
# shellcheck source=Tools/ship/test-stages.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-stages.sh"
# shellcheck source=Tools/ship/lib/linux-unity-kill.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-kill.sh"
# shellcheck source=Tools/ship/lib/linux-unity-shared-files.sh
. "$SHIP_TOOL_DIR/lib/linux-unity-shared-files.sh"
. "$SHIP_TOOL_DIR/lib/linux-unity-supervise.sh"
# shellcheck source=Tools/ship/linux-unity-seat.sh
. "$(dirname "${BASH_SOURCE[0]}")/linux-unity-seat.sh"
die() { log "error: $*"; exit 1; }
# Editor work succeeded but noise cleanup failed: rerun only Tools/ship/scene-noise.sh.
NOISE_REVERT_RC=3

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# shellcheck source=Tools/ship/linux-unity-license.sh
. "$(dirname "${BASH_SOURCE[0]}")/linux-unity-license.sh"
# shellcheck source=Tools/ship/linux-unity-setup.sh
. "$(dirname "${BASH_SOURCE[0]}")/linux-unity-setup.sh"

# Library cache key: bare 64-hex sha256 over the package manifest, lock file, ProjectVersion.txt and the editor
# version, so any package or editor change starts a new cache entry.
cache_key() {
  local f suffix=""
  # The Library differs per build target: `cache_key android` (apk) is a separate entry.
  [ "${1:-}" != android ] || suffix="-android"
  for f in Packages/manifest.json Packages/packages-lock.json ProjectSettings/ProjectVersion.txt; do
    [ -f "$PROJECT/$f" ] || die "cache key: missing $f"
  done
  { cat "$PROJECT/Packages/manifest.json" "$PROJECT/Packages/packages-lock.json" \
      "$PROJECT/ProjectSettings/ProjectVersion.txt"; printf '%s' "$UNITY_VERSION$suffix"; } \
    | sha256sum | cut -c1-64
}

cmd_cache() {
  local op="$1" key
  if ! command -v "$TASK_CACHE" >/dev/null 2>&1; then log "task-cache not found; cache-$op skipped"; return 0; fi
  key="$(cache_key "${2:-}")"
  log "task-cache $op $key Library"
  if [ "$op" = restore ]; then cache_restore "$key"; return 0; fi
  # Android save owns the Bee move/restore lifecycle in apk_cache_save.
  if [ "${2:-}" = android ]; then (cd "$PROJECT" && "$TASK_CACHE" "$op" "$key" Library)
  else supervise cache_save "$key"; fi
}

# Restore with a time limit. On a timeout, miss or error it removes what the restore left behind (a partial Library/
# when there was none before, task-cache's .task-cache.* download dir) and returns 0: the caller imports cold.
cache_restore() {
  local had_library=0 rc=0 supervised_cancel=discard_partial_restore
  [ -d "$PROJECT/Library" ] && had_library=1
  supervise cache_restore_worker "$1" || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then log "cache restore timed out; cold import"
  else log "cache restore failed (exit $rc); cold import"; fi
  discard_partial_restore
  return 0
}

cache_save() { cd "$PROJECT" && exec "$TASK_CACHE" save "$1" Library; }
cache_restore_worker() { cd "$PROJECT" && exec timeout -k 10 "$TASK_CACHE_TIMEOUT" "$TASK_CACHE" restore "$1" Library; }
discard_partial_restore() {
  [ "$had_library" = 1 ] || rm -rf "$PROJECT/Library"
  rm -rf "$PROJECT"/.task-cache.*
}

# Read-only installation scan. Strict mode prints matches but returns 1 if inspection is incomplete:
# an unreadable live userspace process is not evidence of absence. Kernel threads, zombies and exits are exempt.
# shared-files scope additionally scans other installations, reporting executable paths with the PIDs.
unity_pids() {
  local p exe status stat flags editor client unity_match incomplete=0
  local -r PF_KTHREAD=2097152 # Linux task flag (0x00200000), available before Kthread: in status.
  for p in /proc/[0-9]*; do
    case "${p#/proc/}" in "$$"|"$BASHPID") continue ;; esac
    if exe="$(readlink "$p/exe" 2>/dev/null)"; then
      unity_match=0
      case "$exe" in "$UNITY_ROOT"/*) unity_match=1 ;; esac
      if [ "${2:-}" = shared-files ]; then
        # A running Editor/Unity remains identifiable after unlink; keep the raw path for diagnostics.
        case "$exe" in */Editor/Unity" (deleted)") unity_match=1 ;; esac
        editor="${exe%/*}"
        while [ "$unity_match" = 0 ] && [ -n "$editor" ] && [ "$editor" != / ]; do
          if [ "${editor##*/}" = Editor ]; then
            # The bundled licensing client can still identify a partial installation.
            client="$editor/${LC_REL#Editor/}"
            if { [ -f "$editor/Unity" ] && [ -x "$editor/Unity" ]; } ||
              { [ -f "$client" ] && [ -x "$client" ]; }; then
              unity_match=1
            fi
          fi
          editor="${editor%/*}"
        done
        if [ "$unity_match" = 0 ] && [ "${1:-}" = strict ]; then
          # A deleted helper may be all that remains of an unconfirmed Editor tree.
          case "$exe" in */Editor/*" (deleted)") incomplete=1 ;; esac
        fi
        [ "$unity_match" = 0 ] || printf ' %s (%s)' "${p#/proc/}" "${exe//$'\n'/ }"
      else
        [ "$unity_match" = 0 ] || printf ' %s' "${p#/proc/}"
      fi
    elif [ "${1:-}" = strict ]; then
      [ -d "$p" ] || continue
      status="$(cat "$p/status" 2>/dev/null)" || { [ ! -d "$p" ] || incomplete=1; continue; }
      case "$status" in
        *$'\nKthread:\t1'*) continue ;;
        *$'\nState:\tZ '*|*$'\nState:\tX '*) continue ;;
      esac
      # Older kernels omit Kthread: from status; stat field 9 still exposes PF_KTHREAD.
      if stat="$(cat "$p/stat" 2>/dev/null)"; then
        read -r _ _ _ _ _ _ flags _ <<< "${stat##*) }"
        if [[ "$flags" =~ ^[0-9]+$ ]] && (( (flags & PF_KTHREAD) != 0 )); then continue; fi
      fi
      [ ! -d "$p" ] || incomplete=1
    fi
  done
  return "$incomplete"
}

# Kill only this run's editor helpers. A stale Unity.DataStore shared-memory segment makes the next run fail
# with "Error loading the file 'VirtualArtifacts/...'", but a foreign editor may still own those files.
cleanup_unity() {
  lock_unity
  local p run="${LINUX_UNITY_RUN:-}"
  if [ -n "$run" ]; then
    for p in $(marked "$run"); do
      case "$(readlink "/proc/${p%%:*}/exe" 2>/dev/null)" in
        "$UNITY_ROOT"/*) same_proc "$p" "$run" && kill -KILL "${p%%:*}" 2>/dev/null || true ;;
      esac
    done
  fi
  sleep 2 || return
  wipe_unity_shared_files "$@"
}

# One editor run under `timeout -s KILL $UNITY_TIMEOUT`. UNITY_RUN_LABEL (the pass) and UNITY_TIMEOUT_VAR (the
# variable that sets this run's limit) name it in the line printed when it was killed.
unity() {
  local rc=0 start elapsed events baseline
  test_stage activate-reuse start
  ensure_licence
  test_stage activate-reuse end
  test_editor_begin "$@"
  events="$(unity_memory_events_file)"
  baseline="$(unity_memory_events_read "$events")"
  start="$(date +%s.%N)"
  supervise xvfb-run -a -s "-screen 0 1280x1024x24" timeout -s KILL "$UNITY_TIMEOUT" \
    "$UNITY_BIN" -batchmode -projectPath "$PROJECT" "$@" || rc=$?
  activation_unlock
  if [ "$rc" = 137 ]; then
    elapsed="$(LC_ALL=C awk -v start="$start" -v end="$(date +%s.%N)" 'BEGIN { printf "%.6f", end - start }')"
    report_killed "$elapsed" "$events" "$baseline"
  fi
  test_editor_end
  cleanup_unity
  test_stage "${TEST_PASS_STAGE:-pure-pass}" end
  return $rc
}

# Process start time (field 22 of /proc/<pid>/stat, after the comm field that may hold spaces): with the pid it
# identifies one process, so `stop` never kills an unrelated process that reused the pid.
proc_start() {
  local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  set -- ${s##*) }; echo "${20}"
}

# This script's pid and start time ("<pid> <start>") in $PIDFILE ($OUT_DIR/linux-unity.pid, or
# PIDFILE_FALLBACK (default /tmp/linux-unity-<uid>.pid) when unwritable) for the whole command (cache restore, every
# pass and flake rerun, not just while an editor runs). A persistent sidecar lock serializes publication,
# stale reclaim, stop and EXIT cleanup. Never unlink the lock or expose an empty pidfile to another acquirer.
write_pidfile() {
  local pid start i fd
  mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null && [ -w "$(dirname "$PIDFILE")" ] || PIDFILE="$PIDFILE_FALLBACK"
  PID_LINE="$$ $(proc_start "$$" || echo 0)"
  exec {fd}> "$PIDFILE.lock"; flock -x "$fd"
  for i in 1 2 3; do
    if (set -C; printf '%s\n' "$PID_LINE" > "$PIDFILE") 2>/dev/null; then exec {fd}>&-; return 0; fi
    read -r pid start < "$PIDFILE" 2>/dev/null || true
    if [ -n "${pid:-}" ] && [ "$(proc_start "$pid" || true)" = "$start" ]; then
      exec {fd}>&-; PID_LINE=""; die "another run (pid $pid, $PIDFILE) is still going: wait for it or run $SHIP_COMMAND stop"
    fi
    # A dead wrapper can leave workers with its marker and the editor lock.
    if [[ "${pid:-}" =~ ^[1-9][0-9]*$ && "${start:-}" =~ ^[0-9]+$ ]] && [ -n "$(marked "$pid:$start")" ]; then
      exec {fd}>&-; PID_LINE=""; die "workers remain from pid $pid ($PIDFILE): run $SHIP_COMMAND stop"
    fi
    rm -f "$PIDFILE"
  done
  exec {fd}>&-; PID_LINE=""; die "could not create $PIDFILE"
}
release_pidfile() { [ -z "${PID_LINE:-}" ] || (flock -x 7; [ "$(cat "$PIDFILE" 2>/dev/null)" != "$PID_LINE" ] || rm -f "$PIDFILE") 7> "$PIDFILE.lock"; }
# Every descendant of pid $1, deepest first (one pass over /proc).
descendants() {
  local p s ppid; local -A kids=()
  for p in /proc/[0-9]*; do
    read -r s 2>/dev/null < "$p/stat" || continue
    read -r _ ppid _ <<< "${s##*) }"
    kids[$ppid]+=" ${p#/proc/}"
  done
  walk() { local c; for c in ${kids[$1]:-}; do walk "$c"; echo "$c"; done; }
  walk "$1"
}
# Every process carrying run $1's LINUX_UNITY_RUN marker ("<pid>:<start>", exported at the bottom and inherited by
# all it forks, whatever process group, session or parent it ends up in), except this stop, as "<pid>:<start>".
marked() {
  local p s
  for p in $(grep -lzxF -- "LINUX_UNITY_RUN=$1" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 | grep -vx -- "$$" || true); do
    s="$(proc_start "$p")" && echo "$p:$s"
  done
  return 0
}
# True while "<pid>:<start>" $1 is still that process (its pid not reused) and, with run $2, still carries its marker.
same_proc() {
  [ -z "${2:-}" ] || grep -qzxF -- "LINUX_UNITY_RUN=$2" "/proc/${1%%:*}/environ" 2>/dev/null || return 1
  [ "$(proc_start "${1%%:*}" || true)" = "${1#*:}" ]
}

# Kill the run of this script recorded in the pidfile and everything it launched (xvfb-run, Xvfb, timeout, the editor
# and its helpers). Only that process tree: never `pkill -f`, never another editor.
cmd_stop() {
  local f pid start found=0 p procs new i left fd wrapper_live run
  for f in "$PIDFILE" "$PIDFILE_FALLBACK"; do
    [ -d "$(dirname "$f")" ] || continue
    if ! { exec {fd}> "$f.lock"; } 2>/dev/null; then log "stop: cannot open $f.lock; trying next pidfile"; continue; fi
    flock -x "$fd"
    if [ ! -f "$f" ]; then exec {fd}>&-; continue; fi
    found=1
    read -r pid start < "$f" || true
    if ! [[ "${pid:-}" =~ ^[1-9][0-9]*$ && "${start:-}" =~ ^[0-9]+$ ]] || [ "$pid" = "$$" ]; then
      log "stop: invalid owner in $f (stale pidfile removed)"; rm -f "$f"; exec {fd}>&-; continue
    fi
    run="$pid:$start"; wrapper_live=0; procs=""
    if same_proc "$run"; then
      kill -STOP "$pid" 2>/dev/null || true
      wrapper_live=1; procs="$run"
    fi
    # Freeze the script (SIGSTOP), so it starts no further pass, then its tree until a scan finds nothing new: a
    # stopped process forks nothing, so no xvfb-run, Xvfb or editor can appear after the list is taken. Each entry
    # is pid:start, so the KILL after the grace period never hits a pid reused meanwhile.
    # The run's marker also finds what left the tree (orphans, other groups); after the grace period every
    # process still carrying it is KILLed until none is left, so what a TERM handler forked meanwhile (all's
    # licence return) dies too.
    while :; do
      new=0
      # If the wrapper died (or its PID was reused), only the run marker proves
      # ownership. Never walk the tree of a process now using the wrapper PID.
      for p in $(if [ "$wrapper_live" = 1 ] && same_proc "$run"; then descendants "$pid"; fi) $(marked "$run"); do
        case " $procs " in *" ${p%%:*}:"*) continue ;; esac
        case "$p" in *:*) same_proc "$p" "$run" || continue ;; *) p="$p:$(proc_start "$p")" || continue ;; esac
        same_proc "$p" || continue
        kill -STOP "${p%%:*}" 2>/dev/null || true; procs="$procs $p"; new=1
      done
      [ "$new" = 1 ] || break
    done
    if [ -z "$procs" ]; then
      log "stop: pid $pid from $f is not running (stale pidfile removed)"; rm -f "$f"; exec {fd}>&-; continue
    fi
    for p in $procs; do
      same_proc "$p" || continue
      log "stop: killing ${p%%:*} ($(cat "/proc/${p%%:*}/comm" 2>/dev/null || echo gone))"
      kill -TERM "${p%%:*}" 2>/dev/null || true
      same_proc "$p" && kill -CONT "${p%%:*}" 2>/dev/null || true
    done
    sleep 2
    for p in $procs; do
      same_proc "$p" && kill -KILL "${p%%:*}" 2>/dev/null || true
    done
    # Until none is left; each listed pid:start is re-checked (start time and marker) right before its KILL.
    for i in $(seq 50); do
      left=0
      for p in $(marked "$run"); do
        same_proc "$p" "$run" || continue
        left=1; kill -KILL "${p%%:*}" 2>/dev/null || true
      done
      [ "$left" = 1 ] || break; sleep 0.1
    done
    [ "$left" = 0 ] || die "stop: marked workers remain; kept $f for recovery"
    # Verify that inherited descriptors drained before discarding the record.
    lock_unity 2
    rm -f "$f"; exec {fd}>&-
    wipe_unity_shared_files
  done
  [ "$found" = 1 ] || log "stop: no pidfile ($PIDFILE): nothing this script started is running"
  log "stop done"
}
# --keep handling for open and test: `--keep <path>` protects a path from the noise revert, a bare `--keep` (last, or
# followed by an option) skips it. Sets NOISE_SKIP and RUN_KEEP; RUN_ARGS gets the other args.
parse_keep() {
  NOISE_SKIP=0; RUN_KEEP=(); RUN_ARGS=()
  local k
  while [ $# -gt 0 ]; do
    if [ "$1" = --keep ]; then
      if [ $# -lt 2 ] || [[ "$2" == -* ]]; then NOISE_SKIP=1; shift; continue; fi
      k="$(noise_keep_path "$PROJECT" "$2")" || die "--keep $2 is not inside $PROJECT"
      RUN_KEEP+=("$k"); shift 2
    else RUN_ARGS+=("$1"); shift; fi
  done
}

# Dirty files before an editor run (empty outside a git work tree).
run_noise_before() {
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  (cd "$PROJECT" && noise_dirty_files)
}

# After an editor command: revert run noise (scene-noise.sh) unless --keep skipped it.
revert_run_noise_after() {
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if [ "$NOISE_SKIP" = 1 ]; then log "--keep: noise revert skipped"; return 0; fi
  (cd "$PROJECT" && revert_run_noise "$1" ${RUN_KEEP[@]+"${RUN_KEEP[@]}"})
}

# Scene and lab arm this only after capturing the pre-run snapshot. Keep the
# command and its arguments in an array so EXIT can run it even if Bash has
# already unwound the command's locals. chain_exit_trap retains the exit status.
finish_interrupted_noise() {
  [ -n "${NOISE_EXIT_CLEANUP[0]:-}" ] || return 0
  "${NOISE_EXIT_CLEANUP[@]}"
}
NOISE_EXIT_CLEANUP=()

# The editor work succeeded but the noise revert failed with exit $1: save the files dirty before the run ($2) to
# $OUT_DIR/noise-before.txt, print a distinct line ($3: what succeeded) with the scene-noise.sh command that finishes
# the job (remaining args: its extra options), and return NOISE_REVERT_RC.
noise_revert_failed() {
  local nrc="$1" before="$2" what="$3" why cmd k; shift 3
  printf '%s\n' "$before" > "$OUT_DIR/noise-before.txt"
  cmd="$SHIP_NOISE_COMMAND $* --before $(printf %q "$OUT_DIR/noise-before.txt")"
  for k in ${RUN_KEEP[@]+"${RUN_KEEP[@]}"}; do cmd="$cmd --keep $(printf %q "$k")"; done
  if [ "$nrc" = "$NOISE_LOCK_RC" ]; then why="git lock"; else why="exit $nrc"; fi
  log "noise revert failed ($why); $what; rerun $SHIP_NOISE_COMMAND by hand (from $PROJECT): $cmd"
  return "$NOISE_REVERT_RC"
}

cmd_open() {
  parse_keep "$@"
  [ ${#RUN_ARGS[@]} = 0 ] || die "usage: open [--keep [<path>]]..."
  mkdir -p "$OUT_DIR"
  local cold=0 rc=0 nrc=0 before what='project opened and compiled'
  if [ ! -d "$PROJECT/Library" ]; then
    cmd_cache restore
    [ -d "$PROJECT/Library" ] || cold=1
  fi
  cleanup_unity   # a cancelled run can leave Unity.DataStore and its shared memory behind, as before test
  before="$(run_noise_before)"
  unity -nographics -quit -logFile "$OUT_DIR/open.log" || rc=$?
  revert_run_noise_after "$before" || nrc=$?
  if [ "$rc" != 0 ]; then
    if [ "$nrc" != 0 ]; then noise_revert_failed "$nrc" "$before" "open failed" --run || :; fi
    die "Unity failed to open the project (see $OUT_DIR/open.log)"
  fi
  if [ "$nrc" = 0 ]; then log "$what"
  else noise_revert_failed "$nrc" "$before" "$what" --run || nrc=$?; fi
  if [ "$cold" = 1 ]; then cmd_cache save || log "warning: cache-save failed"; fi
  return "$nrc"
}

# Android resource guards, cache policy and build invocation.
. "$(dirname "${BASH_SOURCE[0]}")/lib/android.sh"

# Rebuild configured prefabs, scene and statistics. Revert only bake-only platform overrides.
cmd_scene() {
  ship_config_get 'has("scene")' | grep -qx true || die "scene: no generated scene configured (yetikit.json has no scene block)"
  local keep=() areas=() k
  while IFS= read -r k; do keep+=("$k"); done < <(ship_config_get '.scene.keepPaths[]?')
  while [ $# -gt 0 ]; do
    case "$1" in --keep) [ $# -ge 2 ] || die "scene: --keep needs a path"
        k="$(noise_keep_path "$PROJECT" "$2")" || die "scene: --keep $2 is not inside $PROJECT"
        keep+=("$k"); shift 2 ;;
      --area) [ $# -ge 2 ] || die "scene: --area needs an area name"
        [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] || die "scene: --area $2 is not an area name"
        [ -n "$(ship_config_get '.scene.areaStep // empty')" ] || die "scene: missing key scene.areaStep for --area"
        areas+=(-area "$2"); keep+=("$(ship_config_get '.scene.areasDir')/$2.prefab"); shift 2 ;;
      *) die "usage: scene [--keep <path>]... [--area <Area>]..." ;; esac
  done
  mkdir -p "$OUT_DIR"
  cleanup_unity
  local m step rc=0 noise_before steps=()
  if [ ${#areas[@]} = 0 ]; then
    mapfile -t steps < <(ship_config_get '.scene.steps[]')
  else
    mapfile -t steps < <(ship_config_get '.scene.areaSteps // [.scene.steps[0], .scene.areaStep] | .[]')
  fi
  noise_before="$(cd "$PROJECT" && noise_dirty_files)" || return
  NOISE_EXIT_CLEANUP=(revert_scene_noise_after "$noise_before" ${keep[@]+"${keep[@]}"})
  for m in "${steps[@]}"; do
    step="${m%.*}"; step="${step##*.}"
    log "scene: $m${areas[*]:+ ${areas[*]}}"
    local extra=()
    [ "$m" != "$(ship_config_get '.scene.areaStep // empty')" ] || extra=("${areas[@]}")
    unity -quit -executeMethod "$m" ${extra[@]+"${extra[@]}"} -logFile "$OUT_DIR/scene-$step.log" \
      || { rc=$?; break; }
  done
  local nrc=0
  finish_interrupted_noise || nrc=$?
  NOISE_EXIT_CLEANUP=()
  if [ "$rc" != 0 ]; then
    log "error: $m failed (exit $rc; see $OUT_DIR/scene-$step.log); noise cleanup exit $nrc"
    return "$rc"
  fi
  log "scene rebuilt"
  if [ "$nrc" != 0 ]; then
    RUN_KEEP=(${keep[@]+"${keep[@]}"})
    noise_revert_failed "$nrc" "$noise_before" "scene rebuilt"
  fi
}

revert_scene_noise_after() { (cd "$PROJECT" && revert_scene_noise "$@"); }

cmd_lab() {
  parse_keep "$@"
  [ ${#RUN_ARGS[@]} = 0 ] || die "usage: lab [--keep [<path>]]..."
  local method before rc=0 nrc=0
  method="$(ship_config_get '.labMethod // empty')"
  [ -n "$method" ] || die "lab: missing key labMethod in yetikit.json"
  mkdir -p "$OUT_DIR"
  cleanup_unity
  before="$(run_noise_before)" || return
  NOISE_EXIT_CLEANUP=(revert_run_noise_after "$before")
  log "lab: $method"
  unity -quit -executeMethod "$method" -logFile "$OUT_DIR/scene-lab.log" || rc=$?
  finish_interrupted_noise || nrc=$?
  NOISE_EXIT_CLEANUP=()
  if [ "$rc" != 0 ]; then
    log "error: $method failed (exit $rc; see $OUT_DIR/scene-lab.log); noise cleanup exit $nrc"
    return "$rc"
  fi
  log "lab rebuilt"
  [ "$nrc" = 0 ] || noise_revert_failed "$nrc" "$before" "lab rebuilt" --run
}

# One test pass: results in $OUT_DIR/<stem>.xml, log in <stem>.log. When it fails and every failed test is in
# known-flakes.txt, those rerun once (<stem>-retry.xml/.log, both XMLs kept); a green rerun makes the pass green.
# $1: stem, rest: Unity args.
run_pass() {
  local stem="$1" rc=0 f filter="" complete=0 failures="" failed=() retry_rc=0 args=() UNITY_RUN_LABEL="$1"; shift
  TEST_EVIDENCE_ONLY=0
  # A crashed or killed editor writes no XML: never read a stale one from an earlier run as this pass's flakes.
  rm -f "$OUT_DIR/$stem.xml" "$OUT_DIR/$stem-retry.xml"
  unity "$@" -testResults "$OUT_DIR/$stem.xml" -logFile "$OUT_DIR/$stem.log" || rc=$?
  if ! test_results_summary "$stem" "$OUT_DIR/$stem.xml" "${TEST_ALLOW_EMPTY:-0}"; then
    if [ "$rc" = 0 ]; then rc=1; TEST_EVIDENCE_ONLY=1; fi
    return "$rc"
  fi
  # Unity returns 2 for failed tests. A timeout, signal, or editor error can leave
  # complete XML too, but a passing retry must not hide that process failure.
  [ "$rc" = 2 ] || return "$rc"
  while IFS= read -r -d '' f; do
    if [ -z "$f" ]; then complete=1; break; fi
    is_known_flake "$f" || { log "$stem: $f failed and is not a known flake"; return "$rc"; }
    failed+=("$f")
    failures="${failures:+$failures }$f"
    # A parameterised case reruns as its method (-testFilter takes names, not argument lists).
    f="${f%%(*}"; [[ ";$filter;" == *";$f;"* ]] || filter="${filter:+$filter;}$f"
  done < <(flake_evidence "$OUT_DIR/$stem.xml")
  [ "$complete" = 1 ] && [ -n "$filter" ] || return "$rc" # require complete, nonempty evidence
  log "$stem: only known flakes failed; rerunning once: $filter"
  while IFS= read -r -d '' f; do args+=("$f"); done < <(without_test_filter "$@")
  UNITY_RUN_LABEL="$stem-retry"
  unity ${args[@]+"${args[@]}"} -testFilter "$filter" -testResults "$OUT_DIR/$stem-retry.xml" \
    -logFile "$OUT_DIR/$stem-retry.log" || retry_rc=$?
  test_results_summary "$stem-retry" "$OUT_DIR/$stem-retry.xml" 0 || return "$rc"
  if [ "$retry_rc" = 0 ] && printf '%s\0' "${failed[@]}" | flake_evidence "$OUT_DIR/$stem-retry.xml" retry; then
    failures="${failures//$'\n'/\\n}"
    log "flaky-passed: ${failures//$'\r'/\\r}"
    return 0
  fi
  log "$stem: the known flakes failed again (see $OUT_DIR/$stem-retry.xml)"
  return $rc
}

# run_pass under the Gfx pass's timeout (UNITY_GFX_TIMEOUT).
run_gfx_pass() {
  local UNITY_TIMEOUT="$UNITY_GFX_TIMEOUT" UNITY_TIMEOUT_VAR=UNITY_GFX_TIMEOUT TEST_PASS_STAGE=gfx-pass
  log "$1: Gfx pass, timeout $UNITY_TIMEOUT s"
  run_pass "$@"
}

test_passes() {
  local platform="${1:-}"; shift || true
  case "$platform" in
    editmode) platform=EditMode ;;
    playmode) platform=PlayMode ;;
    pr) test_pr "$@"; return ;;
    *) die "usage: test editmode|playmode|pr [base] [extra Unity args]" ;;
  esac
  local rc=0 gfx_rc=0 TEST_ALLOW_EMPTY=0 TEST_EVIDENCE_ONLY=0
  local TEST_EXECUTED=0 TEST_FILTER="" pure_executed=0
  # No -quit with -runTests.
  if [ "$platform" = PlayMode ]; then
    run_pass playmode -runTests -testPlatform PlayMode "$@" || rc=$?
    return $rc
  fi
  rm -f "$OUT_DIR/editmode.xml" "$OUT_DIR/editmode-gfx.xml"
  local tool
  if ! has_test_option -testCategory "$@" && tool="$(render_tool_filter "$@")"; then
    # [Explicit] render tools match by name only, so the pure (-nographics) pass would pick them up and crash.
    # Adding -testCategory RenderTool would silently drop the other tests of a ;-list, so refuse that mix.
    [[ "$(test_filter_value "$@")" != *";"* ]] \
      || die "test: -testFilter mixes the RenderTool class $tool with other tests; run the render tool on its own"
    log "test: -testFilter names the RenderTool class $tool; one pass on Xvfb with -testCategory RenderTool"
    set -- "$@" -testCategory RenderTool
  fi
  if has_test_option -testCategory "$@"; then
    # Caller picks the categories: one pass with a GL device so render tests also work; Gfx gets its timeout.
    if [[ ";$(test_category_value "$@");" == *";$GFX_CATEGORIES;"* ]]; then
      run_gfx_pass editmode -runTests -testPlatform EditMode "$@" || rc=$?
      return $rc
    fi
    run_pass editmode -runTests -testPlatform EditMode "$@" || rc=$?
    return $rc
  fi
  # Filtered dual-pass runs may be empty per category, but must execute tests in total.
  if [ "${EDITMODE_GFX:-1}" = 1 ] && has_test_option -testFilter "$@"; then
    TEST_FILTER="$(test_filter_value "$@")"; TEST_ALLOW_EMPTY=filtered
  fi
  run_pass editmode -nographics -runTests -testPlatform EditMode -testCategory "$PURE_CATEGORIES" "$@" || rc=$?
  pure_executed=$TEST_EXECUTED
  if [ "${EDITMODE_GFX:-1}" = 1 ]; then
    # Assembly and other forwarded constraints don't request a Gfx pass: it remains optional.
    [ "$TEST_ALLOW_EMPTY" = filtered ] || TEST_ALLOW_EMPTY=1
    run_gfx_pass editmode-gfx -runTests -testPlatform EditMode -testCategory "$GFX_CATEGORIES" "$@" || {
      gfx_rc=$?
      # Missing evidence must not hide an earlier editor failure.
      if [ "$TEST_EVIDENCE_ONLY" = 0 ] || [ "$rc" = 0 ]; then rc=$gfx_rc; fi
    }
    if [ "$rc" = 0 ] && [ "$TEST_ALLOW_EMPTY" = filtered ] && [ "$((pure_executed + TEST_EXECUTED))" = 0 ]; then
      log "test editmode: -testFilter '$TEST_FILTER' matched no executed tests across both passes"
      rc=1
    fi
  fi
  return $rc
}

test_pr() {
  local base=origin/main mb fixtures areas rc=0 gfx_rc=0 TEST_ALLOW_EMPTY=0 TEST_EVIDENCE_ONLY=0
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then base="$1"; shift; fi
  if has_test_option -testFilter "$@" || has_test_option -testCategory "$@"; then
    die "test pr picks the tests itself; use test editmode for -testFilter/-testCategory"
  fi
  mb="$(git -C "$PROJECT" merge-base "$base" HEAD 2>/dev/null)" \
    || die "test pr: no merge-base between $base and HEAD (fetch $base or pass another base)"
  if ! fixtures="$(cd "$PROJECT" && pr_gfx_fixtures "$mb")"; then
    test_stage_log '[linux-unity] test pr: could not determine Gfx selection; running full EditMode passes'
    test_passes editmode "$@"
    return
  fi
  local UNITY_GFX_TIMEOUT="$UNITY_GFX_TIMEOUT"
  pr_gfx_budget "$fixtures"
  areas="$(cd "$PROJECT" && pr_changed_paths "$mb" | pr_areas)"
  if [ -n "$areas" ]; then
    log "test pr: scene areas touched since $base: $(paste -sd' ' <<< "$areas"); their tests (informational; Gfx selection uses class references):"
    printf '  %s\n' $(cd "$PROJECT" && pr_area_tests <<< "$areas") >&2
  fi
  rm -f "$OUT_DIR/editmode.xml" "$OUT_DIR/editmode-gfx.xml"
  run_pr_pure_pass "$mb" "$@" || rc=$?
  if [ -z "$fixtures" ]; then
    log "test pr: no Gfx fixtures touched since $base (${mb:0:12}); Gfx pass skipped"
  elif [ "${EDITMODE_GFX:-1}" != 1 ]; then
    log "test pr: EDITMODE_GFX=0; Gfx pass skipped"
  else
    log "test pr: Gfx fixtures touched since $base (${mb:0:12}):"
    printf '  %s\n' $fixtures >&2
    TEST_ALLOW_EMPTY=1
    run_gfx_pass editmode-gfx -runTests -testPlatform EditMode -testCategory "$GFX_CATEGORIES" \
      -testFilter "$(paste -sd';' <<< "$fixtures")" "$@" || {
        gfx_rc=$?
        if [ "$TEST_EVIDENCE_ONLY" = 0 ] || [ "$rc" = 0 ]; then rc=$gfx_rc; fi
      }
  fi
  return $rc
}

# Class names tagged [Category("RenderTool")] under tests.root (one per line).
render_tool_classes() {
  local f tests_root
  tests_root="$(ship_config_get '.tests.root // "Assets/Tests"')" || return
  [ -d "$PROJECT/$tests_root" ] || return 0
  { grep -rl --include='*.cs' 'Category("RenderTool")' "$PROJECT/$tests_root" 2>/dev/null || true; } | while IFS= read -r f; do
    awk '/Category\("RenderTool"\)/ { want = 1 }
      want && match($0, /class [A-Za-z0-9_]+/) { print substr($0, RSTART + 6, RLENGTH - 6); want = 0 }' "$f"
  done
}

# The value of the caller's -testFilter (empty when there is none).
test_filter_value() {
  local prev=""
  for a in "$@"; do [ "$prev" = -testFilter ] && { printf '%s' "$a"; return; }; prev="$a"; done
}

# The value of the caller's -testCategory (empty when there is none).
test_category_value() {
  local prev=""
  for a in "$@"; do [ "$prev" = -testCategory ] && { printf '%s' "$a"; return; }; prev="$a"; done
}

# Prints the first RenderTool class a caller's -testFilter names (as Class, Ns.Class or Ns.Class.Method, in a
# ;-separated list); fails when it names none.
render_tool_filter() {
  local prev="" a c re classes
  classes="$(render_tool_classes)"
  [ -n "$classes" ] || return 1
  for a in "$@"; do
    if [ "$prev" = -testFilter ]; then
      for c in $classes; do
        re="(^|[;.])$c([;.(]|$)"
        if [[ "$a" =~ $re ]]; then echo "$c"; return 0; fi
      done
    fi
    prev="$a"
  done
  return 1
}

cmd_all() {
  need_creds
  cmd_setup
  cmd_activate
  cmd_open
  cmd_test editmode
}
# Sourced (the shell tests stub a function): define everything, run nothing.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
if [ "${1:-}" = test ]; then
  test_stages_begin defer
  test_stage credentials-seat start
fi
if [ "${1:-}" = scene ] && [ "$(ship_config_get 'has("scene")')" != true ]; then
  die "scene: no generated scene configured (yetikit.json has no scene block)"
fi
if [ "${1:-}" = lab ] && [ -z "$(ship_config_get '.labMethod // empty')" ]; then
  die "lab: missing key labMethod in yetikit.json"
fi
creds_fallback
if [ "${1:-}" = __idle-return ]; then idle_watch; exit; fi
idle_begin
chain_exit_trap idle_finish
case "${1:-}" in
  activate|open|test|scene|lab|apk|all) need_creds ;;
esac
test_stage credentials-seat end
case "${1:-}" in
  open|test|scene|lab|apk|all|setup|cache-restore|cache-save)
    # Every process this run forks inherits the marker, so `stop` finds it in any process group (timeout's,
    # a foreground run's) and never signals a pipeline peer such as `| tee`.
    case "$1" in setup|cache-save) ;; *) lock_unity ;; esac
    write_pidfile; export LINUX_UNITY_RUN="${PID_LINE/ /:}"; chain_exit_trap release_pidfile
    if [ "${1:-}" = test ]; then test_stages_claim; fi ;;
esac
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
# EXIT handlers run in reverse registration order. Return the licence and seat
# before Git lock retries can consume stop's grace period.
case "${1:-}" in scene|lab) chain_exit_trap finish_interrupted_noise ;; esac
arm_seat_exit
arm_return_on_exit
case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  apk) shift; cmd_apk "$@" ;;
  activate) cmd_activate ;;
  return) cmd_return ;;
  open) shift; cmd_open "$@" ;;
  stop) cmd_stop ;;
  cache-restore) cmd_cache restore ;;
  cache-save) cmd_cache save ;;
  cache-key) shift; cache_key "$@" ;;
  scene) shift; cmd_scene "$@" ;;
  lab) shift; cmd_lab "$@" ;;
  test) shift; cmd_test "$@" ;;
  all) cmd_all ;;
  *) printf '# Usage: %s <command>\n' "$SHIP_COMMAND"
     sed -n '2,/^set -euo/p' "$0" | grep '^#'; exit 2 ;;
esac
