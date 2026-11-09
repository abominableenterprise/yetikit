# Shared sandbox setup for the synthetic linux-unity stop suites; sourced, never runs Unity.
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Temp"
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/process-view:$PATH" SHIP_FIXTURE_PIDS=''
bystander=""
# The bystander's sleep is its child: kill both, so no stray process keeps the caller's pipe open.
trap '[ -z "$bystander" ] || kill $(ps -o pid= --ppid "$bystander") "$bystander" 2>/dev/null || true; rm -rf "$tmp"' EXIT
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
# Wait for observed readiness with scheduling headroom.
wait_for() { ship_wait_until test -s "$1"; }
