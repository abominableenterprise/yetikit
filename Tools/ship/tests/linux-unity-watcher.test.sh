#!/usr/bin/env bash
# Watcher retry/context/orphan regressions, using only fake clients/processes.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; orphan=''
trap 'if [ -n "$orphan" ]; then kill "$orphan" 2>/dev/null || true; wait "$orphan" 2>/dev/null || true; fi; if [ -f "$tmp/launch-pids" ]; then while read -r p; do kill "$p" 2>/dev/null || true; done < "$tmp/launch-pids"; fi; rm -rf "$tmp"' EXIT
fails=0; proj="$tmp/proj"; mkdir -p "$proj"
. "$(dirname "$0")/lib/fake-unity.sh"
. "$script"
IDLE_SCRIPT="$script"
UNITY_IDLE_RETURN_MINUTES=0
mkdir -p "$IDLE_ACTIVE"
touch "$IDLE_ACTIVITY"
if [[ "${WATCHER_CASE:-all}" = all || "${WATCHER_CASE:-}" = retry ]]; then
# The watcher must stay alive after failure, with a capped delay and no activity lock held during backoff.
(
  cmd_return() {
    echo attempt >> "$tmp/attempts"
    [ "$(wc -l < "$tmp/attempts")" -ge 6 ] || return 7
    rm -f "$ULF"
  }
  sleep() {
    echo "$1" >> "$tmp/delays"
    flock -n "$IDLE_ACTIVITY_LOCK" true || exit 90
    [ "$(wc -l < "$tmp/delays")" -le 8 ] || exit 91
  }
  idle_watch
)
check 'transient failures retry without a new command until success' '[ "$(wc -l < "$tmp/attempts")" = 6 ] && [ ! -f "$ULF" ]'
check 'retry backoff is bounded, outside activity lock' '[ "$(tr "\n" " " < "$tmp/delays")" = "5 10 20 40 60 60 " ]'
# Use the real return path too: failed attempts must not leak RETURN_ATTEMPTED or activation-lock ownership.
printf licence > "$ULF"
cat > "$tmp/client" <<'EOF'
#!/bin/bash
echo attempt >> "$FAKE_TMP/client-attempts"
[ "$(wc -l < "$FAKE_TMP/client-attempts")" -ge 2 ] || exit 7
EOF
chmod +x "$tmp/client"
(
  LC="$tmp/client"
  sleep() { echo "$1" >> "$tmp/client-delays"; [ "$(wc -l < "$tmp/client-delays")" -le 3 ] || exit 93; }
  idle_watch
)
check 'real return path retries transient client failure and removes licence' '[ "$(wc -l < "$tmp/client-attempts")" = 2 ] && [ ! -f "$ULF" ]'
fi

if [[ "${WATCHER_CASE:-all}" = all || "${WATCHER_CASE:-}" = retirement ]]; then
printf licence > "$ULF"
LINUX_UNITY_RUN=successor /bin/sleep 300 & orphan=$!
(
  sleep() { :; }
  cmd_return() { command rm -f "$ULF"; }
  rm() {
    if [ "$*" = "-f $IDLE_PID" ]; then
      if flock -n "$IDLE_ACTIVITY_LOCK" true; then
        echo unlocked > "$tmp/retired-unlocked"
      fi
    fi
    command rm "$@"
  }
  idle_watch
  [ ! -f "$IDLE_PID" ] || echo advertised > "$tmp/retired-advertised"
  # A successor publishes while the returning outer watcher is stalled before EXIT.
  printf '%s %s\n' "$orphan" "$(proc_start "$orphan")" > "$IDLE_PID"
)
check 'successful return retires advertisement before releasing activity lock' \
  '[ ! -f "$tmp/retired-unlocked" ] && [ ! -f "$tmp/retired-advertised" ]'
check 'retiring watcher EXIT leaves successor advertisement intact' \
  '[ "$(cut -d" " -f1 "$IDLE_PID")" = "$orphan" ]'
kill "$orphan"; wait "$orphan" 2>/dev/null || true; orphan=''
rm -f "$IDLE_PID"

# External return takes the other exit path: stall after idle_watch returns,
# before its EXIT trap, and reactivate in the same context in that interval.
(
  printf licence > "$ULF"
  sleep() { command rm -f "$ULF"; }
  rm() {
    if [ "$*" = "-f $IDLE_PID" ] && flock -n "$IDLE_ACTIVITY_LOCK" true; then
      echo unlocked > "$tmp/external-retired-unlocked"
    fi
    command rm "$@"
  }
  idle_watch
  [ ! -f "$IDLE_PID" ] || echo advertised > "$tmp/external-retired-advertised"
  printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
  context="$(idle_context)"; printf '%s\n' "$context" > "$IDLE_CONTEXT"
  idle_finish
  [ -f "$IDLE_LAUNCH" ] || echo missing > "$tmp/external-replacement-missing"
)
check 'external return retires advertisement under lock before same-context reactivation' \
  '[ ! -f "$tmp/external-retired-unlocked" ] && [ ! -f "$tmp/external-retired-advertised" ] && [ ! -f "$tmp/external-replacement-missing" ]'
# A fatal poll must not leave a live outer watcher advertised until EXIT.
(
  printf licence > "$ULF"
  unset IDLE_WATCH_CONTEXT
  sleep() { command rm -f "$ULF"; }
  activation_lock() { exit 71; }
  rm() {
    if [ "$*" = "-f $IDLE_PID" ] && flock -n "$IDLE_ACTIVITY_LOCK" true; then
      echo unlocked > "$tmp/fatal-retired-unlocked"
    fi
    command rm "$@"
  }
  rc=0; idle_watch || rc=$?
  echo "$rc" > "$tmp/fatal-status"
  [ ! -f "$IDLE_PID" ] || echo advertised > "$tmp/fatal-retired-advertised"
  printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
  context="$(idle_context)"; printf '%s\n' "$context" > "$IDLE_CONTEXT"
  command rm -f "$IDLE_LAUNCH"
  idle_finish
  [ -f "$IDLE_LAUNCH" ] || echo missing > "$tmp/fatal-replacement-missing"
)
check 'fatal no-ULF lock error retires advertisement under lock and permits replacement' \
  '[ "$(cat "$tmp/fatal-status")" = 71 ] && [ ! -f "$tmp/fatal-retired-unlocked" ] && [ ! -f "$tmp/fatal-retired-advertised" ] && [ ! -f "$tmp/fatal-replacement-missing" ]'
fi

if [[ "${WATCHER_CASE:-all}" = all || "${WATCHER_CASE:-}" = orphan ]]; then
# A fake orphan with the dead wrapper marker must keep its activity record until it is gone.
printf licence > "$ULF"
# Keep the dead-wrapper marker unique to this fixture: /proc scans are global,
# so simultaneous suite runs must not discover each other's synthetic orphans.
orphan_run="99999999:$$"
LINUX_UNITY_RUN="$orphan_run" /bin/sleep 300 & orphan=$!
# $! proves fork, not exec: /proc/environ can still belong to the parent
# shell. A zero-grace watcher must see the actual run marker before polling.
ship_wait_until same_proc "$orphan:$(proc_start "$orphan")" "$orphan_run"
printf '%s\n' "$$" > "$IDLE_ACTIVE/99999999"
(
  tick=0
  sleep() {
    tick=$((tick + 1))
    if [ "$tick" = 3 ]; then kill "$orphan"; wait "$orphan" 2>/dev/null || true; fi
    [ "$tick" -le 5 ] || exit 92
  }
  cmd_return() { echo "$tick" > "$tmp/orphan-return"; rm -f "$ULF"; }
  idle_watch
)
check 'surviving run-marked descendant delays idle return after wrapper death' '[ "$(cat "$tmp/orphan-return")" = 3 ]'
kill "$orphan" 2>/dev/null || true; wait "$orphan" 2>/dev/null || true; orphan=''
# A reused PID/start mismatch or changed marker must not count as the recorded process.
LINUX_UNITY_RUN=other /bin/sleep 300 & orphan=$!
identity="$orphan:$(proc_start "$orphan")"
check 'orphan identity rejects wrong start time and wrong marker' '! same_proc "$orphan:0" && ! same_proc "$identity" 99999999:123'
(
  printf licence > "$ULF"
  printf '0\n' > "$IDLE_ACTIVE/$orphan"
  sleep() { :; }
  cmd_return() { rm -f "$ULF"; }
  idle_watch
)
check 'stale run identity does not retain licence' '[ ! -f "$ULF" ]'
kill "$orphan"; wait "$orphan" 2>/dev/null || true; orphan=''

# Force the non-atomic scan gap: the first scan misses a marked survivor (as
# when a parent forks after glob expansion and exits before identity validation).
# The next scan uses real /proc and must still have the run identity to find it.
printf licence > "$ULF"
LINUX_UNITY_RUN="$orphan_run" /bin/sleep 300 & orphan=$!
ship_wait_until same_proc "$orphan:$(proc_start "$orphan")" "$orphan_run"
printf '%s\n' "$$" > "$IDLE_ACTIVE/99999999"
(
  UNITY_IDLE_RETURN_MINUTES=1; tick=0; epoch="$(date +%s)"
  eval "$(declare -f marked | sed '1s/marked/real_marked/')"
  marked() { [ "$tick" = 1 ] || real_marked "$@"; }
  date() { echo "$((epoch + (tick > 1 ? 120 : 0)))"; }
  sleep() {
    tick=$((tick + 1)); [ "$tick" -le 4 ] || exit 94
    if [ "$tick" = 3 ]; then kill "$orphan"; wait "$orphan" 2>/dev/null || true; fi
  }
  cmd_return() { echo "$tick" > "$tmp/handoff-return"; rm -f "$ULF"; }
  idle_watch
)
check 'one empty non-atomic scan does not discard a surviving run identity' \
  '[ "$(cat "$tmp/handoff-return")" = 3 ]'
kill "$orphan" 2>/dev/null || true; wait "$orphan" 2>/dev/null || true; orphan=''

# Deterministic PID reuse: the displaced record names our PID with a different
# start time, while its marked descendant is alive. Beginning the new run must
# not overwrite that displaced identity (no kernel PID wraparound needed).
printf licence > "$ULF"
printf '0\n' > "$IDLE_ACTIVE/$$"
LINUX_UNITY_RUN=$$:0 /bin/sleep 300 & orphan=$!
ship_wait_until same_proc "$orphan:$(proc_start "$orphan")" "$$:0"
idle_begin
check 'new run does not overwrite displaced PID identity' \
  '[ "$(cat "$IDLE_ACTIVE/$$")" = 0 ] && [ -f "$IDLE_ACTIVE/$$:$(proc_start "$$")" ]'
# Prevent the new live wrapper record from masking the orphan under test.
rm -f "$IDLE_ACTIVE/$$:$(proc_start "$$")"
(
  tick=0
  sleep() {
    tick=$((tick + 1)); [ "$tick" -le 4 ] || exit 95
    if [ "$tick" = 3 ]; then kill "$orphan"; wait "$orphan" 2>/dev/null || true; fi
  }
  cmd_return() { echo "$tick" > "$tmp/reused-pid-return"; rm -f "$ULF"; }
  idle_watch
)
check 'displaced PID run remains busy until its marked descendant exits' \
  '[ "$(cat "$tmp/reused-pid-return")" = 3 ]'
kill "$orphan" 2>/dev/null || true; wait "$orphan" 2>/dev/null || true; orphan=''
rm -f "$IDLE_ACTIVE/$$"
fi

if [[ "${WATCHER_CASE:-all}" = all || "${WATCHER_CASE:-}" = context ]]; then
# Exercise launch/reuse with a real live PID, but a fake nohup; metadata contains only a fingerprint.
printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
# Isolate this case from the preceding return/context metadata. Shared watcher
# advertisements without owner metadata retain ownership compatibility.
rm -f "$IDLE_PID" "$IDLE_LAUNCH" "$IDLE_CONTEXT" "$IDLE_OWNER" "$IDLE_SEAT"
: > "$tmp/launches"
printf '#!/bin/bash\necho $$ >> "$FAKE_TMP/launch-pids"\necho launch >> "$FAKE_TMP/launches"\nexec /bin/sleep 300\n' > "$tmp/bin/nohup"; chmod +x "$tmp/bin/nohup"
await_launch() {
  local expected="$1" i pid start context
  for i in {1..1000}; do
    if [ "$(wc -l < "$tmp/launches")" -ge "$expected" ] && [ -s "$IDLE_LAUNCH" ]; then
      read -r pid start context < "$IDLE_LAUNCH" || true
      if [ -n "${pid:-}" ] && [ -n "${start:-}" ] && same_proc "$pid:$start" \
        && [ "$context" = "$(cat "$IDLE_CONTEXT")" ]; then return 0; fi
    fi
    /bin/sleep 0.01
  done
  echo "FAIL fake watcher launch $expected did not become ready"; exit 1
}
unset UNITY_USERNAME UNITY_PASSWORD THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN THEROBOTS_HUB_URL
idle_begin; idle_finish
if [ ! -f "$IDLE_CONTEXT" ]; then echo 'FAIL watcher context was not published'; exit 1; fi
old="$(cat "$IDLE_CONTEXT")"
# Both the child and its context-specific advertisement must be ready.
await_launch 1
idle_begin; idle_finish
check 'unchanged credential-free context reuses watcher' '[ "$(wc -l < "$tmp/launches")" = 1 ]'
UNITY_USERNAME=fake-user; UNITY_PASSWORD=fake-password
idle_begin; idle_finish
await_launch 2
check 'credentialed command replaces credential-free watcher' '[ "$(wc -l < "$tmp/launches")" = 2 ] && [ "$(cat "$IDLE_CONTEXT")" != "$old" ]'
old="$(cat "$IDLE_CONTEXT")"
THEROBOTS_HUB_URL=hub-origin; THEROBOTS_TASK_ID=fake-task; THEROBOTS_TASK_TOKEN=fake-token
idle_begin; idle_finish
await_launch 3
check 'changed hub ownership replaces watcher without storing secrets' '[ "$(wc -l < "$tmp/launches")" = 3 ] && [ "$(cat "$IDLE_CONTEXT")" != "$old" ] && ! grep -Eq "fake-user|fake-password|fake-task|fake-token" "$IDLE_CONTEXT"'
# Missing invocation environment must not revoke a live watcher's release-capable context.
# Model the seat persisted by a prior credentialed activation; all return I/O remains fake.
printf '%s %s\n' "$THEROBOTS_TASK_ID" "$$" > "$SEAT_STATE"
held_context="$(cat "$IDLE_CONTEXT")"
# No pidfile yet: a live detached launcher still owns its release environment.
rm -f "$IDLE_PID"
for downgrade in credentials hub partial-credentials partial-hub; do
  (
    case "$downgrade" in
      credentials) unset UNITY_USERNAME UNITY_PASSWORD ;;
      hub) unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN ;;
      partial-credentials) unset UNITY_PASSWORD ;;
      partial-hub) unset THEROBOTS_TASK_TOKEN ;;
    esac
    idle_begin; idle_finish
  )
  check "$downgrade downgrade preserves release-capable watcher context" \
    '[ "$(cat "$IDLE_CONTEXT")" = "$held_context" ]'
done
# B reuses A's licence without acquiring a seat: A's release-capable watcher must survive.
(
  THEROBOTS_TASK_ID=task-b; THEROBOTS_TASK_TOKEN=token-b
  idle_begin; idle_finish
)
check 'licence reuse by another task preserves persisted seat owner watcher' \
  '[ "$(cat "$IDLE_CONTEXT")" = "$held_context" ] && [ "$(cut -d" " -f1 "$SEAT_STATE")" = fake-task ]'
# Run the original watcher's final poll with its original environment. A context-only
# assertion is insufficient: both licence return and release of its held hub seat must work.
printf '#!/bin/bash\necho returned >> "$FAKE_TMP/downgrade-returns"\n' > "$tmp/client"
printf '#!/bin/bash\necho release >> "$FAKE_TMP/downgrade-releases"\n' > "$tmp/bin/curl"
chmod +x "$tmp/client" "$tmp/bin/curl"
(
  LC="$tmp/client"
  IDLE_WATCH_CONTEXT="$held_context"
  sleep() { :; }
  seat_post() { echo "$THEROBOTS_TASK_ID $1" >> "$tmp/released-owner"; curl; SEAT_CODE=200; }
  idle_watch
)
check 'preserved watcher returns licence and releases original hub seat after downgrades' \
  '[ ! -f "$ULF" ] && [ ! -f "$SEAT_STATE" ] && [ "$(wc -l < "$tmp/downgrade-returns")" = 1 ] && [ "$(wc -l < "$tmp/downgrade-releases")" = 1 ] && [ "$(cat "$tmp/released-owner")" = "fake-task release" ]'
printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
# A replaced watcher must not call return using its old environment, even if it wins the watcher lock.
(
  IDLE_WATCH_CONTEXT="$old"
  sleep() { :; }
  cmd_return() { echo wrong >> "$tmp/wrong-context"; }
  idle_watch
)
check 'obsolete context exits before return' '[ ! -e "$tmp/wrong-context" ]'
# A dead watcher (including a dead launch waiting to publish) must not make stale
# hub capability permanent. A standalone credentialed command must restart it.
while read -r p; do kill "$p" 2>/dev/null || true; done < "$tmp/launch-pids"
printf '99999999 0 %s\n' "$held_context" > "$IDLE_PID"
# A never-existing identity deterministically models a crashed pending launcher.
printf '99999999 0 %s\n' "$held_context" > "$IDLE_LAUNCH"
printf '%s\n' "$held_context" > "$IDLE_CONTEXT"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN
idle_begin; idle_finish
await_launch 4
check 'stale hub context permits standalone watcher recovery' \
  '[ "$(cat "$IDLE_CONTEXT")" != "$held_context" ] && [[ "$(cat "$IDLE_CONTEXT")" = *:1:0 ]]'
(
  IDLE_WATCH_CONTEXT="$(cat "$IDLE_CONTEXT")"
  sleep() { :; }
  cmd_return() { echo returned > "$tmp/standalone-return"; rm -f "$ULF"; }
  idle_watch
)
check 'recovered standalone watcher actually performs idle return' \
  '[ -f "$tmp/standalone-return" ] && [ ! -f "$ULF" ]'
fi
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
