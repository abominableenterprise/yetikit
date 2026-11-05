#!/usr/bin/env bash
# Release a configured Unity project to an attached Quest from macOS.
#
# Usage: Tools/ship/quest-release.sh <command> [args]
#   doctor            read-only Java, SDK, keystore, Unity, disk and headset preflight
#   all [<ref>] [--rollback <apk>] [--force] [--full] [--notes <file>]
#                     prepare, gate/build in parallel, verify, install, launch, cleanup
#   prepare [<ref>]   fetch origin and prepare two clean worktrees (default origin/main)
#   gate [--full]     Metal EditMode Gfx/MacOnly gate, bounded selected-failure retry
#   build [--notes <file>]
#                     configured build.devMethod; retain the APK using quest.apkKeepName
#   verify [<apk>]    Unity launcher contract, configured checks and signer SHA-256
#   install [<apk>] [--force]
#                     idle check, verified backup, install -r only, unchanged data check
#   rollback <apk> [--force]
#                     same checks with install -r -d; never uninstall or clear data
#   launch            start Unity GameActivity, bounded logcat capture and crash check
#   cleanup           remove release worktrees only when safe
#   summary           print the current run summary
#   wait [minutes]    read-only, default 45; exit 0 success, 1 failure, 124 timeout
#
# Mutating commands hold a run lock; device operations also hold a headset lock.
# Env overrides: see README.md, Quest release. Bash 3.2 compatible.

QR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QR_SHIP_DIR="$QR_DIR"
# shellcheck source=Tools/ship/quest-release/common.sh
. "$QR_DIR/quest-release/common.sh"
# shellcheck source=Tools/ship/quest-release/prepare.sh
. "$QR_DIR/quest-release/prepare.sh"
# shellcheck source=Tools/ship/quest-release/unity-steps.sh
. "$QR_DIR/quest-release/unity-steps.sh"
# shellcheck source=Tools/ship/test-passes.sh
. "$QR_DIR/test-passes.sh" # failed_tests, known_flakes, is_known_flake (shared with linux-unity.sh)
# shellcheck source=Tools/ship/quest-release/flakes.sh
. "$QR_DIR/quest-release/flakes.sh"
# shellcheck source=Tools/ship/quest-release/verify.sh
. "$QR_DIR/quest-release/verify.sh"
# shellcheck source=Tools/ship/quest-release/device.sh
. "$QR_DIR/quest-release/device.sh"
# shellcheck source=Tools/ship/quest-release/idle.sh
. "$QR_DIR/quest-release/idle.sh"
# shellcheck source=Tools/ship/quest-release/java.sh
. "$QR_DIR/quest-release/java.sh"
# shellcheck source=Tools/ship/quest-release/lock.sh
. "$QR_DIR/quest-release/lock.sh"
# shellcheck source=Tools/ship/quest-release/doctor.sh
. "$QR_DIR/quest-release/doctor.sh"
# shellcheck source=Tools/ship/quest-release/wait.sh
. "$QR_DIR/quest-release/wait.sh"

. "$QR_DIR/quest-release/config.sh"

# gate and build at once (two editors, two projects, separate -logFile and output), then wait for both.
qr_parallel_unity() {
  local full="$1" gpid bpid grc=0 brc=0
  qr_log "gate and build in parallel (gate.out, build.out)"
  # shellcheck disable=SC2086 # $full is empty or --full
  ( qr_gate $full ) > "$QR_RUN_DIR/gate.out" 2>&1 &
  gpid=$!
  ( qr_build ) > "$QR_RUN_DIR/build.out" 2>&1 &
  bpid=$!
  wait "$gpid" || grc=$?
  wait "$bpid" || brc=$?
  qr_log "gate exit $grc, build exit $brc"
  [ "$grc" = 0 ] || sed -n 's/^\[quest-release\] //p; /^FAIL /p' "$QR_RUN_DIR/gate.out" | tail -n 20 >&2
  [ "$brc" = 0 ] || tail -n 5 "$QR_RUN_DIR/build.out" >&2
  QR_GATE_RC="$grc"; QR_BUILD_RC="$brc"
}

qr_all() {
  local ref="" rollback="" force="" full="" apk rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --rollback) rollback="${2:-}"; [ -n "$rollback" ] || qr_die "--rollback needs an APK"; shift ;;
      --force) force=--force ;;
      --full) full=--full ;;
      --notes) qr_notes_option "${2:-}"; shift ;;
      -*) qr_die "all: unknown option $1" ;;
      *) ref="$1" ;;
    esac
    shift
  done
  [ -z "$rollback" ] || [ -f "$rollback" ] || qr_die "--rollback APK $rollback does not exist"
  ( qr_prepare "$ref" ) || return 1
  qr_load_state
  ( qr_keystore_preflight ) || { qr_set install "skipped: wrong debug keystore"; return 1; }
  QR_KEYSTORE_CHECKED=1
  qr_parallel_unity "$full"
  if [ "$QR_BUILD_RC" != 0 ]; then
    qr_set install "skipped: build failed"
    qr_log "build failed: nothing to install; worktrees kept"
    return 1
  fi
  apk="$(qr_get apk "")"
  if [ "$QR_GATE_RC" != 0 ]; then
    qr_set install "skipped: gate failed (APK kept: $apk)"
    qr_set cleanup "kept for the gate failure (run cleanup when done)"
    qr_log "gate failed: not installing; APK kept at $apk"
    return 1
  fi
  ( qr_verify "$apk" ) || { qr_set install "skipped: verify failed"; return 1; }
  # shellcheck disable=SC2086 # $force is empty or --force
  ( qr_install "$apk" $force ) || return 1
  if ! ( qr_launch ); then
    rc=1
    if [ -n "$rollback" ]; then
      qr_log "launch shows a crash: rolling back to $rollback"
      ( qr_rollback "$rollback" --force ) || qr_log "rollback failed"
    else
      qr_log "launch shows a crash and no --rollback <apk> was given"
    fi
  fi
  ( qr_cleanup ) || true
  return "$rc"
}

qr_usage() { sed -n '2,/^# Env overrides/p' "$QR_DIR/quest-release.sh" | sed 's/^# \{0,1\}//' >&2; }

# Dispatch one command. Each step runs in a subshell, so qr_die ends that step only; the summary always prints.
qr_main() {
  local cmd="${1:-}" rc=0
  [ $# -gt 0 ] && shift
  case "$cmd" in ''|-h|--help|help) qr_usage; return 0 ;; esac
  qr_config || return 1
  # doctor is read-only: no logs folder, run folder, lock or summary.
  if [ "$cmd" = doctor ]; then
    qr_select_device || return 1
    ( qr_doctor "$@" ) || rc=$?; return "$rc"
  fi
  # wait is read-only too: it only watches the current run.
  if [ "$cmd" = wait ]; then ( qr_wait "$@" ) || rc=$?; return "$rc"; fi
  mkdir -p "$QR_LOGS" 2>/dev/null
  case "$cmd" in
    all|prepare|gate|build|verify|install|launch|rollback|cleanup)
      qr_lock_acquire || return 1 # before qr_load_state: a refused run writes no current.env
      trap 'qr_lock_release' EXIT
      trap 'qr_cancel "$cmd" HUP' HUP
      trap 'qr_cancel "$cmd" INT' INT
      trap 'qr_cancel "$cmd" TERM' TERM
      case "$cmd" in all|prepare) ;; *) qr_load_state; qr_lock_note_run ;; esac ;;
  esac
  # Publish invocation identity and install traps before discovery: an early failure must replace old success.
  case "$cmd" in
    all|install|rollback|launch)
      qr_select_device || { qr_lock_result "$cmd" 1; return 1; } ;;
  esac
  # verify's apksigner and the keystore preflight need Java: find it before any prepare, gate or build work.
  case "$cmd" in all|build|verify) qr_java_setup || { qr_lock_result "$cmd" 1; return 1; } ;; esac
  case "$cmd" in
    all) qr_run_step qr_all "$@" || rc=$? ;;
    prepare) qr_run_step qr_prepare "$@" || rc=$? ;;
    gate|build|verify|install|launch|rollback|cleanup)
      qr_load_state
      qr_run_step "qr_$cmd" "$@" || rc=$? ;;
    summary) qr_load_state ;;
    ''|-h|--help|help) qr_usage; return 0 ;;
    *) qr_usage; qr_log "unknown command '$cmd'"; return 2 ;;
  esac
  [ -f "$(qr_state_file)" ] && qr_load_state
  qr_summary
  qr_lock_result "$cmd" "$rc"
  qr_lock_release
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  qr_main "$@"
  exit $?
fi
