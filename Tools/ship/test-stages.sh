# shellcheck shell=bash
# Observational timing only: no editor invocations, cache restores or licence changes.
# Sourced by linux-unity.sh. All times are elapsed whole seconds from `test` entry.
test_stages_begin() {
  TEST_STAGES_START=$SECONDS
  TEST_STAGES_LOG="" TEST_STAGES_PENDING=""
  [ "${1:-}" = defer ] || test_stages_claim
}
# Credential timing starts before ownership; publish it only after acquiring the
# pidfile so a refused overlapping invocation cannot alter the owner's log.
test_stages_claim() {
  mkdir -p "$OUT_DIR"
  TEST_STAGES_LOG="$OUT_DIR/test-stages.log"
  printf '%s' "$TEST_STAGES_PENDING" > "$TEST_STAGES_LOG"
  TEST_STAGES_PENDING=""
}
test_stage() {
  [ -n "${TEST_STAGES_START:-}" ] || return 0
  local line="[linux-unity] stage $1 $2 +$((SECONDS - TEST_STAGES_START))s"
  printf '%s\n' "$line" >&2
  if [ -n "${TEST_STAGES_LOG:-}" ]; then
    printf '%s\n' "$line" >> "$TEST_STAGES_LOG"
  else
    TEST_STAGES_PENDING+="$line"$'\n'
  fi
}

# Import/compilation live inside the editor process, not separate shell commands.
# Follow its fresh log without changing its output or exit status. Some warm runs
# have no compilation markers: close the remaining scopes at editor exit instead.
test_editor_stages() {
  local file="$1" done_file="$2" phase=import line kind pending="" finished=0
  test_stage editor-launch-import start
  # unity() creates the fresh log before starting this observer. Keep one file
  # descriptor so each line is read once, even during a long, noisy import.
  exec 8< "$file"
  while :; do
    # Snapshot completion before draining: if it arrives during a read, drain
    # again next poll before stopping. read consumes partial bytes even at EOF.
    [ ! -e "$done_file" ] || finished=1
    while :; do
      if IFS= read -r line <&8; then
        line="$pending$line"; pending=""
      elif [ "$finished" = 1 ] && [ -n "$pending$line" ]; then
        line="$pending$line"; pending=""
      else
        pending+="$line"
        break
      fi
      kind=line
      case "$line" in
        *ScriptCompilation*|*Starting:*csc*|*Starting:*bee_backend*|*Begin\ MonoManager\ ReloadAssembly*) kind=compile ;;
        *Completed\ reload*|*Finished\ compiling\ scripts*|*Reloading\ assemblies\ after\ finishing\ script\ compilation*) kind=compiled ;;
        *Running\ tests*|*Test\ run\ started*|*TestRunner:\ Running*) kind=tests ;;
      esac
      case "$phase:$kind" in
        import:compile|import:tests)
          test_stage editor-launch-import end
          test_stage compile start
          phase=compile ;;
      esac
      case "$phase:$kind" in
        compile:compiled|compile:tests)
          test_stage compile end
          phase=done ;;
      esac
    done
    [ "$finished" = 0 ] || break
    sleep 0.1
  done
  exec 8<&-
  if [ "$phase" = import ]; then
    test_stage editor-launch-import end
    test_stage compile start
  fi
  [ "$phase" = done ] || test_stage compile end
}

test_results_summary() {
  test_stage results start
  summary "$@"
  test_stage results end
}

# Keep observer ownership outside unity()'s locals so EXIT can clean it up even
# when cancellation skips the normal test_editor_end call.
test_editor_begin() {
  [ -n "${TEST_STAGES_LOG:-}" ] || return 0
  local arg previous="" stage_log=""
  for arg in "$@"; do
    [ "$previous" != -logFile ] || stage_log="$arg"
    previous="$arg"
  done
  test_stage "${TEST_PASS_STAGE:-pure-pass}" start
  if [ -z "${TEST_STAGE_CLEANUP_ARMED:-}" ]; then
    chain_exit_trap test_editor_end
    TEST_STAGE_CLEANUP_ARMED=1
  fi
  TEST_STAGE_DONE="$(mktemp "$OUT_DIR/.test-stage.XXXXXX")"; rm -f "$TEST_STAGE_DONE"
  # Never consume stale milestones from an earlier invocation of this pass.
  : > "$stage_log"
  test_editor_stages "$stage_log" "$TEST_STAGE_DONE" & TEST_STAGE_OBSERVER=$!
}
test_editor_end() {
  [ -n "${TEST_STAGE_OBSERVER:-}" ] || return 0
  : > "$TEST_STAGE_DONE"
  wait "$TEST_STAGE_OBSERVER" || true
  rm -f "$TEST_STAGE_DONE"
  TEST_STAGE_OBSERVER="" TEST_STAGE_DONE=""
}

# Keep test orchestration here to leave linux-unity.sh below its size ceiling.
cmd_test() {
  parse_keep "$@"
  set -- ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}
  validate_test_args "$@"
  local before rc=0 nrc=0 f
  mkdir -p "$OUT_DIR"
  if [ -z "${TEST_STAGES_LOG:-}" ]; then test_stages_begin; fi
  # test has no shell cache-restore step (unlike open); retain that behaviour.
  test_stage cache-restore start
  log "test: cache restore skipped (editor uses the existing Library or imports cold)"
  test_stage cache-restore end
  cleanup_unity
  before="$(run_noise_before)"
  test_passes "$@" || rc=$?
  test_stage noise-revert start
  revert_run_noise_after "$before" || nrc=$?
  test_stage noise-revert end
  [ "$nrc" != 0 ] || return $rc
  # Preserve a test failure; otherwise reprint totals and the noise recovery command.
  [ "$rc" = 0 ] || { log "the noise revert failed too (exit $nrc)"; return $rc; }
  for f in ${RUN_RESULTS[@]+"${RUN_RESULTS[@]}"}; do [ ! -f "$f" ] || test_results_summary "$f"; done
  noise_revert_failed "$nrc" "$before" "tests passed" --run
}
