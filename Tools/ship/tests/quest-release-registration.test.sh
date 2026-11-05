#!/usr/bin/env bash
# Regression: cancellation after the editor fork but before supervisor registration,
# and failure to publish editor.pid. Test-only DEBUG instrumentation; no Unity or device.
set -u
ci_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
fails=0
owner=""

live_group() {
  ps -axo pgid=,stat= | awk -v group="$1" \
    '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }'
}
live_pid() {
  ps -p "$1" -o stat= 2>/dev/null | grep -q '^[[:space:]]*[^Z[:space:]]'
}
stop_case() {
  local f pid
  # Only groups created by this fixture; never search by process name. Include the outer
  # group to clean qr_timebox's fallback watchdog and its sleep on assertion/setup failure.
  if [ -n "$owner" ]; then
    kill -KILL -- "-$owner" 2>/dev/null || true
    wait "$owner" 2>/dev/null || true
    owner=""
  fi
  for f in "$tmp"/case-*/group.pid; do
    [ -s "$f" ] || continue
    read -r pid < "$f"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
}
cleanup() { stop_case; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
check() {
  if eval "$2"; then printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n' "$1"
    [ ! -f "$REG_CASE/output" ] || tail -n 20 "$REG_CASE/output"
    fails=$((fails + 1))
  fi
}
wait_file() {
  local deadline=$((SECONDS + 5))
  while [ ! -s "$1" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}
finish_owner() {
  local deadline=$((SECONDS + 5))
  bounded=1
  while live_pid "$owner"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      bounded=0
      kill -KILL -- "-$owner" 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  rc=0; wait "$owner" 2>/dev/null || rc=$?
}

# All read gates have time limits and use inherited, already-open FIFOs, so DEBUG never
# creates a child process that changes $! or an unbounded open(2) wait at the race boundary.
# The supervisor's private $! capture is for observation/cleanup ONLY, not production state.
cat > "$tmp/bash-env" <<'ENV'
registration_debug() {
  local cmd="$1" launched="$2"
  case "${0##*/}:$REG_PHASE" in
    editor:cancel)
      if [ "$cmd" = 'pid=$!' ]; then
        printf '%s\n' "$launched" > "$REG_CASE/fork.pid"
        printf '%s\n' "$$" > "$REG_CASE/supervisor.pid"
        printf 'ready\n' > "$REG_CASE/supervisor.ready"
        read -r -t 10 _ <&8 || true
      fi ;;
    editor-group:*)
      case "$cmd" in
        *editor.pid*)
          trap - DEBUG
          printf '%s\n' "$$" > "$REG_CASE/group.pid"
          if [ "$REG_PHASE" = cancel ]; then
            # Pause before the publication, not after: the attempt cannot discover this
            # group through editor.pid when it handles the cancellation signal.
            printf 'ready\n' > "$REG_CASE/group.ready"
            read -r -t 10 _ <&9 || exit 91
          else
            # EISDIR is deterministic even when tests run as root. An atomic publication
            # must also fail to replace this directory, and must never exec the editor.
            mkdir "${0%/*}/editor.pid" || exit 92
            printf 'injected\n' > "$REG_CASE/publication.ready"
          fi ;;
      esac ;;
  esac
}
case "${0##*/}" in
  editor|editor-group) trap 'registration_debug "$BASH_COMMAND" "$!"' DEBUG ;;
esac
ENV
cat > "$tmp/worker" <<'WORKER'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$REG_CASE/worker.pid"
trap 'exit 143' TERM HUP
printf 'ready\n' > "$REG_CASE/worker.ready"
# No descendant sleeps to orphan, and a backstop even if the test harness is interrupted.
read -r -t 12 _ <&7 || true
WORKER
cat > "$tmp/fake editor" <<'EDITOR'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$REG_CASE/editor.pid"
if [ "$REG_PHASE" = publication ]; then exit 0; fi
trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM HUP
"$REG_TMP/worker" & child=$!
wait "$child"
EDITOR
cat > "$tmp/run" <<'RUN'
#!/usr/bin/env bash
set +m
. "$REG_CI/quest-release/common.sh"
. "$REG_CI/quest-release/unity-steps.sh"
qr_android_user_home() { printf '%s\n' "$REG_CASE/android"; }
# Exercise the real unity()/qr_timebox fallback, independent of the host's gtimeout.
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = gtimeout ]; then return 1; fi
  builtin command "$@"
}
QR_RUN_DIR="$REG_CASE/run"
QR_BUILD_TIMEOUT=15; QR_BUILD_STALL_SECONDS=15
UNITY_BIN="$REG_TMP/fake editor"
qr_editor_dir() { printf '%s\n' "$REG_TMP/editor"; } # This regression isolates fork registration.
qr_unity_bin() { printf '%s\n' "$UNITY_BIN"; }
qr_build_attempt "$REG_CASE/unity.log" -logFile "$REG_CASE/unity.log"
RUN
chmod +x "$tmp/worker" "$tmp/fake editor"
export REG_CI="$ci_dir" REG_TMP="$tmp"

for phase in cancel publication; do
  export REG_PHASE="$phase" REG_CASE="$tmp/case-$phase"
  mkdir -p "$REG_CASE/run"
  mkfifo "$REG_CASE/supervisor-gate" "$REG_CASE/group-gate" "$REG_CASE/worker-gate"
  exec 7<> "$REG_CASE/worker-gate"
  exec 8<> "$REG_CASE/supervisor-gate"
  exec 9<> "$REG_CASE/group-gate"
  # The attempt/timebox/supervisor share this outer group. The generated supervisor
  # isolates only editor-group and its workers, just as the real release step does.
  set -m
  BASH_ENV="$tmp/bash-env" bash "$tmp/run" > "$REG_CASE/output" 2>&1 & owner=$!
  set +m
  ready=1; group=""
  if [ "$phase" = cancel ]; then
    wait_file "$REG_CASE/supervisor.ready" || ready=0
    wait_file "$REG_CASE/group.ready" || ready=0
    supervisor=""; fork=""
    [ ! -s "$REG_CASE/supervisor.pid" ] || read -r supervisor < "$REG_CASE/supervisor.pid"
    [ ! -s "$REG_CASE/fork.pid" ] || read -r fork < "$REG_CASE/fork.pid"
    [ ! -s "$REG_CASE/group.pid" ] || read -r group < "$REG_CASE/group.pid"
    registered=0
    for f in "$REG_CASE"/run/build-watch.*/editor.pid; do
      [ ! -s "$f" ] || registered=1
    done
    check 'fixture reaches fork/PID-assignment boundary with a live, unpublished editor group' \
      '[ "$ready" = 1 ] && [ -n "$group" ] && [ "$fork" = "$group" ] && [ "$registered" = 0 ] && live_group "$group"'
    if [ "$ready" = 1 ] && [ -n "$group" ]; then
      kill -TERM -- "-$owner" 2>/dev/null || true
      # Let the vulnerable supervisor take its empty-pid signal path before allowing
      # publication. A fixed supervisor may instead stay alive waiting for registration;
      # release both gates after this bounded observation so that handshake can complete.
      deadline=$((SECONDS + 1))
      while live_pid "$supervisor" && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
      printf 'release\n' >&8
      printf 'release\n' >&9
    fi
    finish_owner
    # Give a surviving pre-publication child a chance to exec and fork its worker, or
    # a correctly cancelled group a chance to disappear. No fixed startup sleeps.
    deadline=$((SECONDS + 2))
    while [ -n "$group" ] && live_group "$group" && [ ! -s "$REG_CASE/worker.ready" ]; do
      [ "$SECONDS" -lt "$deadline" ] || break
      sleep 0.05
    done
    check 'cancellation before pid=$! drains the isolated editor group before returning' \
      '[ "$ready" = 1 ] && [ "$bounded" = 1 ] && [ "$rc" != 0 ] && [ -n "$group" ] && ! live_group "$group"'
  else
    wait_file "$REG_CASE/publication.ready" || ready=0
    finish_owner
    check 'fixture deterministically makes editor.pid publication fail' \
      '[ "$ready" = 1 ] && grep -q "[Ii]s a directory" "$REG_CASE/output"'
    check 'failed editor.pid publication fails closed without executing the editor' \
      '[ "$ready" = 1 ] && [ "$bounded" = 1 ] && [ "$rc" != 0 ] && [ ! -e "$REG_CASE/editor.pid" ]'
  fi
  check "$phase: attempt removes its tracking directory" \
    '[ -z "$(find "$REG_CASE/run" -type d -name "build-watch.*" -print)" ]'
  stop_case
  exec 7>&-; exec 8>&-; exec 9>&-
done
if [ "$fails" != 0 ]; then printf '%s failed\n' "$fails"; exit 1; fi
echo 'all passed'
