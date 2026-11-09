#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# Open preserves foreign helpers and removes stale shared files before fake-editor launch.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-open-cleanup.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

good_ulf > "$ULF"

# Open preserves an unmarked helper and its files; a later open with no foreign helper wipes stale files.
cp /bin/sleep "$root/Editor/Data/Unity.DataStore"
env -u LINUX_UNITY_RUN "$root/Editor/Data/Unity.DataStore" 300 & stale=$!; echo "$stale" > "$tmp/stale.pid"
export SHIP_FIXTURE_PIDS="$stale"
helper_ready() { [ "$(readlink "/proc/$stale/exe" 2>/dev/null)" = "$root/Editor/Data/Unity.DataStore" ]; }
ship_wait_until helper_ready
: > "$tmp/shm/udsMem1234"; : > "$tmp/shm/sem.udsMem1234"; : > "$proj/Temp/UnityLockfile"; : > "$tmp/shm/other"
check "open succeeds with a foreign helper" 'lu open'
check "open: foreign shared memory and the lockfile remain at editor launch" \
  'grep -q udsMem1234 "$tmp/at-launch" && grep -qx lockfile "$tmp/at-launch" && grep -qx other "$tmp/at-launch"'
check "open: an unmarked Unity.DataStore helper survives with a warning" \
  'kill -0 "$stale" && grep -qx datastore "$tmp/at-launch" && grep -q "PIDs:.*$stale.*skipping" "$tmp/err"'
kill "$stale"; wait "$stale" 2>/dev/null || true; rm -f "$tmp/stale.pid"
check "open succeeds without a foreign helper" 'lu open'
check "open: stale shared memory and the lockfile are gone before the editor starts" \
  '! grep -qE "udsMem|lockfile" "$tmp/at-launch" && grep -qx other "$tmp/at-launch"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
