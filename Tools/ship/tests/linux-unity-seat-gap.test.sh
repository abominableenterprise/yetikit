#!/usr/bin/env bash
# Recheck the seat after linux-unity-license.sh reacquires the activation lock.
# Drive the real idle watcher in seat_acquire's unlocked gap; no Unity/network.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; proj="$tmp/project"; mkdir -p "$proj"
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
export THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=gap-task THEROBOTS_TASK_TOKEN=stub-token
export GAP_SCRIPT="$script"
cat > "$tmp/run-gap" <<'EOF'
set -euo pipefail
. "$GAP_SCRIPT"
# Save the real helper, injecting the watcher only after its first return.
eval "$(declare -f seat_acquire | sed '1s/seat_acquire/gap_acquire/')"
acquisitions=0
seat_acquire() {
  acquisitions=$((acquisitions + 1))
  [ "$acquisitions" -le 3 ] || die 'seat retry loop did not converge'
  gap_acquire
  if [ "$acquisitions" = 1 ]; then
    [ ! -f "$ULF" ] && seat_held
    [ -z "${ACTIVATION_FD:-}" ] || die 'watcher gap still holds activation lock'
    # The previous same-task watcher sees the invalid ULF moved aside. Its
    # normal no-ULF path locks, releases the hub lease and removes the marker.
    (idle_watch)
    [ ! -f "$SEAT_STATE" ] || die 'watcher did not release the seat'
  fi
}
seat_post() {
  printf '%s\n' "$1" >> "$FAKE_TMP/events"
  if [ "$1" = acquire ]; then
    [ -z "${ACTIVATION_FD:-}" ] || die 'seat acquisition under activation lock'
  fi
  SEAT_CODE=200; SEAT_BODY='{"status":"acquired"}'; SEAT_RETRY=1; SEAT_ERR=''
  if [ "$1" = acquire ] && [ "$GAP_ANSWER" = fail ]; then SEAT_CODE=500; fi
  if [ "$1" = acquire ] && [ "$GAP_ANSWER" = wait ]; then SEAT_CODE=202; fi
}
# Fail if acquisition/polling holds the activation lock: the previous watcher
# must be free to release a seat while an activator waits for capacity.
sleep() { [ -z "${ACTIVATION_FD:-}" ] || die 'polling under activation lock'; }
UNITY_SEAT_WAIT_MINUTES=0
activate_client() {
  if seat_held; then echo licensed-with-seat; else echo licensed-without-seat; fi >> "$FAKE_TMP/events"
  printf '<root><License/><Signature>x</Signature></root>\n' > "$ULF"
}
LC=/bin/true
mkdir -p "$IDLE_DIR" "$(dirname "$SEAT_STATE")"
printf '%s 111\n' "$THEROBOTS_TASK_ID" > "$SEAT_STATE"
printf 'invalid ULF\n' > "$ULF"
cmd_activate
EOF
for answer in acquire fail wait; do
  rm -rf "$ULF.idle"; rm -f "$ULF" "$OUT_DIR/unity-seat.held"
  : > "$tmp/events"
  rc=0
  GAP_ANSWER="$answer" timeout -k 1 10 bash "$tmp/run-gap" > "$tmp/log" 2>&1 || rc=$?
  check "$answer: watcher releases the previous seat in the unlocked gap" \
    'grep -qx release "$tmp/events" && grep -q "already holds a Unity seat" "$tmp/log" && [ "$(find "$tmp" -maxdepth 1 -name "ulf.invalid-*" | wc -l)" -ge 1 ]'
  check "$answer: licensing never starts without a seat" \
    '! grep -qx licensed-without-seat "$tmp/events"'
  if [ "$answer" = acquire ]; then
    check 'lost seat is reacquired before licensing starts' \
      '[ "$rc" = 0 ] && [ "$(tr "\n" " " < "$tmp/events")" = "release acquire licensed-with-seat " ] && [ -f "$OUT_DIR/unity-seat.held" ]'
  else
    check "$answer: failed/queued reacquisition prevents licensing" \
      '[ "$rc" != 0 ] && [ "$rc" != 124 ] && grep -qx acquire "$tmp/events" && ! grep -q "^licensed-" "$tmp/events" && [ ! -f "$ULF" ] && [ ! -f "$OUT_DIR/unity-seat.held" ]'
  fi
done
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
