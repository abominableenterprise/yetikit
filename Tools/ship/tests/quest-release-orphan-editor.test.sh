#!/usr/bin/env bash
# Fake editors only: exercise the real timebox, build watchdog and run lock.
set -u
ship="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
. "$ship/quest-release.sh"
export ORPHAN_SHIP="$ship" ORPHAN_TMP="$tmp"
owner=""; step=""; editor=""; fails=0
stop_case() {
  local group
  for group in "$step" "$editor"; do
    [ -z "$group" ] || kill -KILL -- "-$group" 2>/dev/null || true
  done
  if [ -n "$owner" ]; then
    kill -KILL "$owner" 2>/dev/null || true
    wait "$owner" 2>/dev/null || true
  fi
  owner=""; step=""; editor=""
}
trap 'stop_case; rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
check() {
  if eval "$2"; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); fi
}
cat > "$tmp/editor" <<'EDITOR'
#!/usr/bin/env bash
trap '' TERM HUP INT
# The worker remains even if the editor exits. A bounded read backs up fixture cleanup.
(read -r -t 15 _ <&7 || true) &
worker=$!
printf '%s\n' "$worker" > "$ORPHAN_CASE/worker.pid"
printf '%s\n' "$$" > "$ORPHAN_CASE/editor.pid"
wait "$worker"
EDITOR
chmod +x "$tmp/editor"
cat > "$tmp/run" <<'RUN'
. "$ORPHAN_SHIP/quest-release.sh"
QR_LOGS="$ORPHAN_CASE/logs"; QR_RUN_DIR="$ORPHAN_CASE"
UNITY_BIN="$ORPHAN_TMP/editor"
qr_editor_dir() { :; }
qr_android_user_home() { printf '%s\n' "$ORPHAN_CASE/android"; }
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = gtimeout ]; then return 1; fi
  builtin command "$@"
}
qr_lock_acquire || exit 1
trap qr_lock_release EXIT
case "$1" in
  gate) QR_UNITY_TIMEOUT=30 qr_run_step unity ;;
  build) QR_BUILD_TIMEOUT=30 QR_BUILD_STALL_SECONDS=30 qr_run_step qr_build_attempt "$ORPHAN_CASE/unity.log" ;;
  successor) : > "$ORPHAN_CASE/dispatched" ;;
esac
RUN
wait_for_editor() {
  local i
  for ((i=0; i<100; i++)); do
    if [ -s "$ORPHAN_CASE/editor.pid" ] && read -r editor < "$ORPHAN_CASE/editor.pid"; then return 0; fi
    sleep 0.05
  done
  return 1
}
for kind in gate build; do
  export ORPHAN_CASE="$tmp/$kind"
  mkdir -p "$ORPHAN_CASE/logs"
  mkfifo "$ORPHAN_CASE/hold"; exec 7<> "$ORPHAN_CASE/hold"
  bash "$tmp/run" "$kind" > "$ORPHAN_CASE/output" 2>&1 & owner=$!
  if ! wait_for_editor || ! read -r step < "$ORPHAN_CASE/logs/run.lock/group"; then
    printf 'FAIL %s: editor or step did not start\n' "$kind"
    tail -n 20 "$ORPHAN_CASE/output"
    exit 1
  fi
  check "$kind: editor is in a live group separate from the step" \
    '[ "$editor" != "$step" ] && qr_group_alive "$editor" && qr_group_alive "$step"'
  if [ "$kind" = gate ]; then
    # With no owner left to drain, a successor must not reclaim until the
    # registered editor group is gone, even when both leaders are dead.
    kill -KILL "$owner" 2>/dev/null; wait "$owner" 2>/dev/null; owner=""
    kill -KILL -- "-$step"; kill -KILL "$editor"
    for ((i=0; i<100; i++)); do
      qr_group_alive "$step" || break
      sleep 0.05
    done
    bash "$tmp/run" successor >> "$ORPHAN_CASE/output" 2>&1; rc=$?
    check 'dead owner and step: surviving editor child blocks reclaim and dispatch' \
      '[ "$rc" = 1 ] && qr_group_alive "$editor" && [ ! -e "$ORPHAN_CASE/dispatched" ]'
    kill -KILL -- "-$editor" 2>/dev/null || true
    for ((i=0; i<100; i++)); do
      qr_group_alive "$editor" || break
      sleep 0.05
    done
    bash "$tmp/run" successor >> "$ORPHAN_CASE/output" 2>&1; rc=$?
    check 'confirmed editor group exit permits the next invocation' \
      '[ "$rc" = 0 ] && [ -f "$ORPHAN_CASE/dispatched" ] && [ ! -d "$ORPHAN_CASE/logs/run.lock" ]'
  else
    kill -KILL -- "-$step"
    for ((i=0; i<100; i++)); do
      [ -d "$ORPHAN_CASE/logs/run.lock" ] || break
      sleep 0.05
    done
    check 'live owner drains the isolated build editor and child before unlocking' \
      '[ ! -d "$ORPHAN_CASE/logs/run.lock" ] && ! qr_group_alive "$editor"'
  fi
  stop_case
  exec 7>&-
done
[ "$fails" = 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
printf 'all passed\n'
