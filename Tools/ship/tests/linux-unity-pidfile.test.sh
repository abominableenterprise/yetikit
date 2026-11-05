#!/usr/bin/env bash
# Deterministic publication/reclaim races; sourced wrappers only, never Unity.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="${PIDFILE_TEST_SCRIPT:-$repo/Tools/ship/linux-unity.sh}"
tmp="$(mktemp -d)"; pids=()
cleanup() {
  touch "$tmp/proceed" "$tmp/finish"
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
# Loading the validated consumer config is part of each child startup. Wait
# for its explicit gate, not an assumed sub-five-second source time.
wait_for() { ship_wait_until test -e "$1"; }
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$tmp/project"
export OUT_DIR="$tmp/out" PIDFILE_FALLBACK="$tmp/fallback.pid"
mkdir -p "$OUT_DIR"
export GATE_TMP="$tmp"
# Pause precisely inside the winning writer: after O_EXCL creation but before
# publication, or after classifying an old pidfile as stale but before unlink.
# The first writer's deadline covers BOTH shells loading before we open its gate.
for mode in publication reclaim fallback; do
  rm -f "$tmp/entered" "$tmp/proceed" "$tmp/finish" "$tmp/second-entered" "$tmp/second-done" "$tmp/second-won"
  export PIDFILE="$OUT_DIR/linux-unity.pid"
  [ "$mode" != fallback ] || { touch "$tmp/notadir"; export PIDFILE="$tmp/notadir/run.pid"; }
  [ "$mode" != reclaim ] || echo '99999999 0' > "$PIDFILE"
  timeout -k 5 180 bash -c '
    . "$1"
    wait_gate() { deadline=$((SECONDS + 150)); while [ ! -e "$GATE_TMP/$1" ]; do [ "$SECONDS" -lt "$deadline" ] || exit 1; /bin/sleep 0.02; done; }
    if [ "$2" = reclaim ]; then
      rm() {
        if [ "$*" = "-f $PIDFILE" ] && [ ! -e "$GATE_TMP/entered" ]; then
          touch "$GATE_TMP/entered"; wait_gate proceed
        fi
        command rm "$@"
      }
    else
      printf() {
        touch "$GATE_TMP/entered"; wait_gate proceed
        builtin printf "$@"
      }
    fi
    write_pidfile
    touch "$GATE_TMP/first-won"
    wait_gate finish
    release_pidfile
  ' _ "$script" "$mode" > "$tmp/first.log" 2>&1 & first=$!; pids+=("$first")
  wait_for "$tmp/entered"
  timeout -k 5 90 bash -c '
    . "$1"
    flock() {
      if [ "$1" = -x ]; then
        command flock -n "${!#}" && return 0
        touch "$GATE_TMP/second-entered"
      fi
      command flock "$@"
    }
    write_pidfile
    touch "$GATE_TMP/second-won"
  ' _ "$script" > "$tmp/second.log" 2>&1 & second=$!; pids+=("$second")
  wait_for "$tmp/second-entered"
  # The contender has actually observed the held publication lock.
  check "$mode: competing acquisition waits for ownership publication" \
    'kill -0 "$second" 2>/dev/null && [ ! -e "$tmp/second-won" ]'
  touch "$tmp/proceed"
  rc=0; wait "$second" || rc=$?
  check "$mode: only the first writer owns the published pidfile" \
    '[ "$rc" != 0 ] && [ ! -e "$tmp/second-won" ] && grep -q "another run" "$tmp/second.log"'
  touch "$tmp/finish"; wait "$first"
  chosen="$PIDFILE"; [ "$mode" != fallback ] || chosen="$PIDFILE_FALLBACK"
  check "$mode: owner cleanup removes its advertisement" '[ ! -f "$chosen" ]'
  rm -f "$tmp/first-won"
done
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
