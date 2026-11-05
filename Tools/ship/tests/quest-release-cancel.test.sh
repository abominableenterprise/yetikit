#!/usr/bin/env bash
# Cancellation of the lock owner must stop the whole active step before recording failure.
# Only fake release steps and short-lived shell children; no Unity or device.
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/quest-release.sh"
fixture_lib="$(dirname "$script")/tests/lib/quest-release-fixture.sh"
. "$fixture_lib"
export FIXTURE_LIB="$fixture_lib"
# nohup makes HUP ignored at entry, which Bash cannot undo with trap. Reset it
# before exec, just like INT/QUIT for asynchronous suite launches. Workers keep
# using the shared helper; only the signalled owner needs normal HUP disposition.
qr_fixture_bash() {
  exec perl -e '$SIG{HUP} = "DEFAULT"; $SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV; die "exec: $!"' bash "$@"
}
CANCELLATION_TIMEOUT_SECONDS=60 # far below each fake child's 300-second lifetime
export TIMEBOX_TIMEOUT_SECONDS=30 # includes loaded editor/compiler readiness
qr_fixture_watchdog() {
  local owner="$1" timer=""
  trap 'kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null; exit' TERM
  command sleep "$CANCELLATION_TIMEOUT_SECONDS" & timer=$!
  wait "$timer"
  echo "fixture cancellation exceeded ${CANCELLATION_TIMEOUT_SECONDS}s: $CANCEL_PHASE (owner $owner)" >&2
  cat "$CANCEL_TMP/out" >&2
  kill -KILL "$owner" 2>/dev/null
}
tmp="$(mktemp -d)"
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (ready=${ready:-?}, rc=${rc:-?}, stopped=${stopped:-?})"; ls -l "$tmp"; cat "$tmp/out"; fails=$((fails + 1)); fi; }
export QUEST_LOG_ROOT="$tmp/logs" QUEST_WT_ROOT="$tmp/wt" CANCEL_TMP="$tmp" RELEASE_SCRIPT="$script"
# Exercise GNU timeout's real process-group behavior when available (Linux timeout / Mac gtimeout).
mkdir -p "$tmp/bin"
timeout_bin="$(command -v gtimeout || command -v timeout || true)"
if [ -n "$timeout_bin" ]; then
  ln -s "$timeout_bin" "$tmp/bin/gtimeout"
else
  printf '#!/bin/sh\n[ "$1" = --foreground ] || exit 99\nshift 4\nexec "$@"\n' > "$tmp/bin/gtimeout"
  chmod +x "$tmp/bin/gtimeout"
fi
export PATH="$tmp/bin:$PATH"
cat > "$tmp/worker.sh" <<'WORKER'
#!/usr/bin/env bash
. "$FIXTURE_LIB"
name="$1"
echo "$$" > "$CANCEL_TMP/$name.pid"
trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; sleep 0.1; [ ! -f "$QUEST_LOG_ROOT/last-result" ] || touch "$CANCEL_TMP/early-result"; echo done > "$CANCEL_TMP/$name.stopped"; exit 1' TERM HUP
if [ "$CANCEL_PHASE" = stubborn ]; then trap '' TERM; fi
if [ "$CANCEL_PHASE" = stopped ]; then
  # Model a credential helper stopped on terminal input while its parent is still waiting normally.
  bash -c 'trap "exit 1" TERM; kill -STOP $$; sleep 300' & child=$!
  deadline=$((SECONDS + 60))
  while ! ps -p "$child" -o stat= | grep -q T; do
    [ "$SECONDS" -lt "$deadline" ] || exit 1
    sleep 0.05
  done
else
  sleep 300 & child=$!
fi
echo "$child" > "$CANCEL_TMP/$name-child.pid"
qr_fixture_ready "$CANCEL_TMP/$name.ready" "$name"
[ "$CANCEL_PHASE" != registration ] || echo registered >&8
wait "$child"
echo unexpected > "$CANCEL_TMP/$name.finished"
WORKER
cat > "$tmp/run.sh" <<'RUN'
. "$RELEASE_SCRIPT"
qr_java_setup() { :; }
qr_keystore_preflight() { :; }
qr_prepare() {
  qr_new_run abc origin/main
  qr_lock_note_run
  if [ "$CANCEL_PHASE" = prepare ]; then bash "$CANCEL_TMP/worker.sh" prepare; fi
}
qr_gate() {
  case "$CANCEL_PHASE" in timeout*) return 0 ;; esac
  if [ "$CANCEL_PHASE" = timebox ]; then qr_timebox 300 bash "$CANCEL_TMP/worker.sh" gate
  elif [ "$CANCEL_PHASE" = watchdog ]; then PATH=/usr/bin:/bin qr_timebox 300 bash "$CANCEL_TMP/worker.sh" gate
  else bash "$CANCEL_TMP/worker.sh" gate; fi
}
qr_build() {
  case "$CANCEL_PHASE" in
    timeout*)
      if [ "$CANCEL_PHASE" = timeout-watchdog ]; then PATH=/usr/bin:/bin; fi
      # The real timeout includes process startup; keep headroom for the
      # compiler readiness handshake, checked explicitly by the test owner.
      qr_timebox "$TIMEBOX_TIMEOUT_SECONDS" bash "$CANCEL_TMP/editor.sh"
      return $? ;;
  esac
  bash "$CANCEL_TMP/worker.sh" build
}
qr_verify() { echo verify >> "$CANCEL_TMP/later"; }
qr_install() { echo install >> "$CANCEL_TMP/later"; }
qr_launch() { echo launch >> "$CANCEL_TMP/later"; }
qr_cleanup() { echo cleanup >> "$CANCEL_TMP/later"; }
if [ "$CANCEL_PHASE" = registration ]; then
  # Deterministically deliver TERM after launch but immediately before the PID assignment, without changing
  # release code. The worker handshake ensures the group is live and owns children at this exact boundary.
  set -T
  trap 'if [ "$BASH_COMMAND" = '\''QR_ACTIVE_STEP=$!'\'' ]; then read -r -t 60 _ <&8; kill -TERM "$$"; fi' DEBUG
fi
qr_main "$CANCEL_CMD"
RUN

for sig in TERM HUP INT; do
  for phase in prepare parallel standalone timebox watchdog registration stubborn stopped; do
    # One deterministic registration / escalation / stopped-process regression is enough.
    case "$phase:$sig" in registration:TERM|stubborn:INT|stopped:TERM) ;; registration:*|stubborn:*|stopped:*) continue ;; esac
    rm -rf "$tmp/logs"; rm -f "$tmp"/*.pid "$tmp"/*.stopped "$tmp"/*.finished "$tmp/later" "$tmp/early-result" "$tmp"/*.ready
    rm -f "$tmp/registration"; mkfifo "$tmp/registration"
    # Open both ends so the registration handshake cannot block while the worker starts.
    exec 8<> "$tmp/registration"
    export CANCEL_PHASE="$phase" CANCEL_CMD=all
    case "$phase" in standalone|timebox|watchdog|registration|stubborn|stopped) CANCEL_CMD=gate ;; esac
    # Job control prevents a new async INT ignore; the launcher also resets an inherited ignore before exec.
    set -m
    qr_fixture_bash "$tmp/run.sh" > "$tmp/out" 2>&1 & owner=$!
    set +m
    if [ "$phase" = parallel ]; then workers='gate build'; elif [ "$phase" = prepare ]; then workers=prepare; else workers=gate; fi
    ready=1
    for worker in $workers; do
      qr_fixture_wait_ready "$tmp/$worker.ready" "$owner" || ready=0
    done
    recorded="$(cat "$tmp/logs/run.lock/pid" 2>/dev/null)"
    cancelled_at=$SECONDS
    if [ "$phase" != registration ]; then [ "$recorded" != "$owner" ] || kill -"$sig" "$recorded"; fi
    # A missing trap or stuck drain is a failure, not an unbounded test-suite hang.
    qr_fixture_watchdog "$owner" & watchdog=$!
    rc=0; wait "$owner" || rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null || true
    exec 8>&-
    echo "info $sig during $phase: exit $rc after $((SECONDS - cancelled_at))s (bound ${CANCELLATION_TIMEOUT_SECONDS}s)"
    stopped=1
    for pidfile in "$tmp"/*.pid; do
      [ -f "$pidfile" ] || continue
      pid="$(cat "$pidfile")"
      if ps -p "$pid" -o stat= | grep -qv '^[[:space:]]*Z'; then
        stopped=0; kill -KILL "$pid" 2>/dev/null
      fi
    done
    if [ "$phase" != stubborn ]; then
      for worker in $workers; do [ -f "$tmp/$worker.stopped" ] || stopped=0; done
    fi
    for worker in $workers; do [ ! -f "$tmp/$worker.finished" ] || stopped=0; done
    check "$sig during $phase forwards to every child and waits for cleanup, without later release stages" \
      '[ "$ready" = 1 ] && [ "$recorded" = "$owner" ] && [ "$rc" = 1 ] && [ "$stopped" = 1 ] && [ ! -f "$tmp/later" ] && [ ! -f "$tmp/early-result" ] && [ ! -e "$tmp/logs/run.lock" ] && grep -q "^pid=$owner$" "$tmp/logs/last-result" && grep -q "^rc=1$" "$tmp/logs/last-result"'
  done
done
# A fake compiler outlives the editor, ignores TERM, and notices if publication happens before it is killed.
cat > "$tmp/compiler.sh" <<'COMPILER'
. "$FIXTURE_LIB"
trap '' TERM INT
sleep 300 & child=$!
echo "$child" > "$CANCEL_TMP/compiler-child.pid"
echo "$$" > "$CANCEL_TMP/compiler.pid"
qr_fixture_ready "$CANCEL_TMP/compiler.ready" compiler
while :; do
  [ ! -f "$QUEST_LOG_ROOT/last-result" ] || touch "$CANCEL_TMP/early-result"
  sleep 0.05
done
COMPILER
cat > "$tmp/editor.sh" <<'EDITOR'
trap 'exit 1' TERM
bash "$CANCEL_TMP/compiler.sh" &
wait
EDITOR
for phase in timeout-gtimeout timeout-watchdog; do
  if [ "$phase" = timeout-gtimeout ] && [ -z "$timeout_bin" ]; then
    echo 'skip timeout-gtimeout: neither gtimeout nor timeout is installed (watchdog coverage still runs)'
    continue
  fi
  rm -rf "$tmp/logs"; rm -f "$tmp"/*.pid "$tmp/early-result" "$tmp/later" "$tmp"/*.ready
  export CANCEL_PHASE="$phase" CANCEL_CMD=all
  qr_fixture_bash "$tmp/run.sh" > "$tmp/out" 2>&1 & owner=$!
  ready=1
  qr_fixture_wait_ready "$tmp/compiler.ready" "$owner" || ready=0
  cancelled_at=$SECONDS
  qr_fixture_watchdog "$owner" & watchdog=$!
  rc=0; wait "$owner" || rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null || true
  echo "info $phase: exit $rc after $((SECONDS - cancelled_at))s (bound ${CANCELLATION_TIMEOUT_SECONDS}s)"
  stopped=1
  for pidfile in "$tmp"/*.pid; do
    pid="$(cat "$pidfile")"
    if ps -p "$pid" -o stat= | grep -qv '^[[:space:]]*Z'; then stopped=0; kill -KILL "$pid"; fi
  done
  check "$phase drains compiler descendants before failure publication and lock release" \
    '[ "$ready" = 1 ] && [ "$rc" = 1 ] && [ "$stopped" = 1 ] && [ ! -f "$tmp/early-result" ] && [ ! -f "$tmp/later" ] && [ ! -e "$tmp/logs/run.lock" ] && grep -q "^rc=1$" "$tmp/logs/last-result" && grep -q "timed out after ${TIMEBOX_TIMEOUT_SECONDS}s" "$tmp/out"'
done
# Assert the stopped-job protocol explicitly: some shells resume stopped jobs on their own during exit,
# so the integration scenario alone cannot establish that every credential helper receives CONT after TERM.
(
  . "$RELEASE_SCRIPT"
  QR_ACTIVE_STEP=12345; QR_LOGS="$tmp/protocol"; mkdir -p "$QR_LOGS"
  kill() { printf '%s\n' "$*" >> "$tmp/signals"; }
  wait() { :; }
  ps() { :; }
  qr_summary() { :; }
  qr_cancel prepare TERM
) > "$tmp/out" 2>&1
check "cancellation explicitly resumes stopped group members after TERM" \
  '[ "$(head -n2 "$tmp/signals")" = "-TERM -- -12345
-CONT -- -12345" ]'
if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo 'all passed'
