#!/usr/bin/env bash
# Real timeboxes and non-exec adb wrappers; never calls a device.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release.sh"
. "$here/lib/quest-release-timebox.sh"
tmp="$(mktemp -d)"
cleanup() {
  local pid file
  for file in "$tmp"/*.pid; do
    [ -f "$file" ] || continue
    read -r pid < "$file"
    if live_pid "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
ln -s "$(command -v gtimeout || command -v timeout)" "$tmp/bin/gtimeout"
cat > "$tmp/bin/adb" <<'ADB'
#!/bin/bash
# The wrapper exits on TERM while its child ignores TERM. A delayed client
# could keep a substitution open or issue a broadcast after cleanup returns.
trap 'exit 143' TERM
printf '%s\n' "$$" > "$FIXTURE_PREFIX.wrapper.pid"
bash -c 'trap "" TERM; echo "$$" > "$FIXTURE_PREFIX.pid"; read -r -t 5 _ <&8; echo completed > "$FIXTURE_PREFIX.late"; printf "4242\nqr_pid_rc=0\n"' &
wait "$!"
ADB
chmod +x "$tmp/bin/adb"
export PATH="$tmp/bin:$PATH"
export FIXTURE_PREFIX
mkfifo "$tmp/client-delay"
exec 8<> "$tmp/client-delay"
fail=0
check() {
  if [ "$2" = 0 ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n' "$1"; fail=1; fi
}
live_pid() { ps -p "$1" -o stat= 2>/dev/null | grep -q '^[[:space:]]*[^Z[:space:]]'; }
client_stopped() {
  local pid
  [ -s "$FIXTURE_PREFIX.pid" ] || return 1
  read -r pid < "$FIXTURE_PREFIX.pid"
  # An orphan may already be dead but still waiting for the host init to reap it.
  ! live_pid "$pid" || return 1
  read -r pid < "$FIXTURE_PREFIX.wrapper.pid"
  ! kill -0 "$pid" 2>/dev/null
}
for backend in fallback gtimeout; do
  (
    [ "$backend" != fallback ] || qr_test_no_gtimeout
    QR_STEP_GROUP=1 # Exercise the formerly foreground-only lane for real release steps.
    QR_LAUNCH_INFRA=3; QR_PKG=com.synthetic.app; QUEST_SERIAL=synthetic
    QR_RUN_DIR="$tmp"; QR_PERF_RUN_ROOT="$tmp"; QR_PERF_RESTORE_WAIT=1
    FIXTURE_PREFIX="$tmp/$backend-probe"
    rc=0
    result="$(QR_TIMEBOX_KILL_AFTER=1 qr_launch_pid qr_timebox 1 adb -s "$QUEST_SERIAL")" || rc=$?
    status=0
    [ "$rc" = 3 ] && [ -z "$result" ] && [ ! -e "$FIXTURE_PREFIX.late" ] && client_stopped || status=1
    check "$backend: timed-out non-exec adb probe closes inherited stdout within its budget" "$status"

    FIXTURE_PREFIX="$tmp/$backend-restore"
    perf_prox=1; perf_error='capture cancelled'
    rc=0; qr_perf_restore 2> "$tmp/restore.err" || rc=$?
    status=0
    [ "$rc" = 3 ] && [ "$perf_prox" = 1 ] && [ ! -e "$FIXTURE_PREFIX.late" ] && client_stopped || status=1
    check "$backend: restoration timeout stops delayed client before returning" "$status"
    exit "$fail"
  ) || fail=1
done
exit "$fail"
