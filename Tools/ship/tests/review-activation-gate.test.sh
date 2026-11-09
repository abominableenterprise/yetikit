#!/usr/bin/env bash
# Focused regressions for linux-unity-seat.sh and linux-unity-license.sh.
set -euo pipefail
if [ ! -d /proc/self/fd ]; then
  echo 'SKIP: activation descriptor-leak checks require /proc/self/fd'
  exit 0
fi
tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
workers=()
cleanup() {
  local pid
  for pid in "${workers[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  if [ -f "$tmp/workers" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$tmp/workers"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
export OUT_DIR="$tmp/out" ULF="$tmp/licence" FIXTURE_DIR="$tmp"
export UNITY_USERNAME=fixture UNITY_PASSWORD=synthetic
unset ACQUISITION_FD ACTIVATION_FD THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN
source "$tool_dir/linux-unity-seat.sh"
source "$tool_dir/linux-unity-license.sh"
log() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
failures=0
check() {
  if "$@"; then echo "PASS: $1"; else echo "FAIL: $1" >&2; failures=$((failures + 1)); fi
}

# A live worker deliberately retains the gate descriptor. Closing the parent's
# descriptor alone must not strand the lock; explicit unlock releases it for all.
activation_gate
sleep 60 &
workers+=("$!")
if flock -n "$ULF.acquire.lock" true; then
  echo 'FAIL: gate did not serialize activators' >&2; exit 1
fi
activation_ungate
check flock -n "$ULF.acquire.lock" true
check kill -0 "${workers[0]}"
check test -z "${ACQUISITION_FD:-}"
# Allow subsequent checks to run even against the unfixed production code.
kill "${workers[0]}"; wait "${workers[0]}" 2>/dev/null || true
[ "$failures" = 0 ] || exit 1

# Simulate successful activation with a worker outliving the licensing client.
# All licensing entry points must run without either wrapper lock descriptor.
cat > "$tmp/client" <<'CLIENT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$FIXTURE_DIR/calls"
for descriptor in /proc/$$/fd/*; do
  target="$(readlink "$descriptor" || true)"
  case "$target" in
    "$ULF.lock"|"$ULF.acquire.lock") printf '%s\n' "$1:$target" >> "$FIXTURE_DIR/leaked" ;;
  esac
done
case "$1" in
  --activate-ulf)
    printf '<License><Signature>synthetic</Signature></License>\n' > "$ULF"
    sleep 60 &
    echo "$!" >> "$FIXTURE_DIR/workers" ;;
  --showEntitlements) echo 'Product Name: fixture' ;;
  --return-ulf) : ;;
  *) exit 2 ;;
esac
CLIENT
chmod +x "$tmp/client"
LC="$tmp/client"
SHIP_COMMAND=fixture
# Exercise both normal gate release and wrapper EXIT cleanup between runs.
for run in 1 2; do
  (
    # Do not chain the fixture's own temporary-directory cleanup into the wrapper.
    trap - EXIT
    cmd_activate
    cmd_return
    seat_cleanup
    [ ! -f "$ULF" ]
  )
done
check test ! -f "$tmp/leaked"
check test "$(grep -c '^--activate-ulf$' "$tmp/calls")" = 2
check test "$(grep -c '^--showEntitlements$' "$tmp/calls")" = 2
check test "$(grep -c '^--return-ulf$' "$tmp/calls")" = 2
while read -r pid; do check kill -0 "$pid"; done < "$tmp/workers"
exit "$((failures != 0))"
