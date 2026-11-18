# Shared sandbox setup for the synthetic linux-unity stop suites; sourced, never runs Unity.
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Temp"
. "$(dirname "${BASH_SOURCE[0]}")/fake-unity.sh"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/process-view:$PATH" SHIP_FIXTURE_PIDS=''
. "$(dirname "${BASH_SOURCE[0]}")/linux-unity-readiness-runner.sh"
bystander=""
cleanup_stop_fixture() {
  cleanup_readiness_runner
  # The bystander's sleep is its child: kill both so neither holds the caller's pipe open.
  if [ -n "$bystander" ]; then
    kill $(ps -o pid= --ppid "$bystander") "$bystander" 2>/dev/null || true
    wait "$bystander" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup_stop_fixture EXIT
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
# Wait for observed readiness with scheduling headroom.
wait_for() { ship_wait_until ship_read_line "$1" >/dev/null; }
