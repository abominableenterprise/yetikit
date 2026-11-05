#!/usr/bin/env bash
# Tests the Library cache key and the cache-restore/cache-save subcommands of linux-unity.sh.
# Uses a fake project and a stub task-cache under a temp dir; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-cache.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
# Never reach the real hub or the checkout's build/ (a hub task VM exports THEROBOTS_*; build/unity-seat.held marks
# its real seat): `return` below would release that seat while the real licence is still active.
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN SEAT_STATE
export OUT_DIR="$tmp/out" ULF="$tmp/ulf"
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

proj="$tmp/proj"; mkdir -p "$proj/Packages" "$proj/ProjectSettings" "$tmp/bin"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
printf '{"dependencies":{}}\n' > "$proj/Packages/manifest.json"
printf '{"dependencies":{},"lock":1}\n' > "$proj/Packages/packages-lock.json"
printf 'm_EditorVersion: 6000.6.6f1\n' > "$proj/ProjectSettings/ProjectVersion.txt"
version="$(jq -r .unityVersion "$proj/yetikit.json")"
# Stub task-cache: records its arguments and the directory it ran in.
cat > "$tmp/bin/task-cache" <<EOF
#!/bin/sh
echo "\$* @ \$(pwd)" >> "$tmp/calls"
EOF
chmod +x "$tmp/bin/task-cache"

key() { PROJECT="$proj" bash "$script" cache-key 2>"$tmp/err"; }
expected="$({ cat "$proj/Packages/manifest.json" "$proj/Packages/packages-lock.json" \
  "$proj/ProjectSettings/ProjectVersion.txt"; printf '%s' "$version"; } | sha256sum | cut -c1-64)"

k1="$(key)"
check "key is bare 64 lowercase hex" '[[ "$k1" =~ ^[0-9a-f]{64}$ ]]'
check "key is sha256(manifest + lock + ProjectVersion + editor version)" '[ "$k1" = "$expected" ]'
check "key is stable" '[ "$(key)" = "$k1" ]'
printf '{"dependencies":{"x":"1"}}\n' > "$proj/Packages/manifest.json"
check "manifest change changes the key" '[ "$(key)" != "$k1" ]'
printf '{"dependencies":{}}\n' > "$proj/Packages/manifest.json"
printf '{"dependencies":{},"lock":2}\n' > "$proj/Packages/packages-lock.json"
check "lock file change changes the key" '[ "$(key)" != "$k1" ]'
printf '{"dependencies":{},"lock":1}\n' > "$proj/Packages/packages-lock.json"
check "restored inputs give the same key" '[ "$(key)" = "$k1" ]'
rm "$proj/ProjectSettings/ProjectVersion.txt"
check "missing input fails" '! key && grep -q "missing ProjectSettings/ProjectVersion.txt" "$tmp/err"'
printf 'm_EditorVersion: 6000.6.6f1\n' > "$proj/ProjectSettings/ProjectVersion.txt"

PATH="$tmp/bin:$PATH" PROJECT="$proj" bash "$script" cache-restore 2>/dev/null
PATH="$tmp/bin:$PATH" PROJECT="$proj" bash "$script" cache-save 2>/dev/null
check "cache-restore calls task-cache restore <key> Library in the project" \
  'grep -qx "restore $k1 Library @ $proj" "$tmp/calls"'
check "cache-save calls task-cache save <key> Library in the project" \
  'grep -qx "save $k1 Library @ $proj" "$tmp/calls"'
rm -f "$tmp/calls"
check "no task-cache: cache-restore is a no-op that succeeds" \
  'TASK_CACHE=no-such-task-cache PROJECT="$proj" bash "$script" cache-restore 2>/dev/null && [ ! -e "$tmp/calls" ]'

# A restore slower than TASK_CACHE_TIMEOUT is abandoned: logged, partial Library/ and download dir removed, exit 0.
printf '#!/bin/sh\nmkdir -p Library/partial .task-cache.x\nexec /bin/sleep 300\n' > "$tmp/bin/slow-task-cache"
chmod +x "$tmp/bin/slow-task-cache"
# Completion is bounded far below the blocked downloader's lifetime; startup
# scheduling is not part of the production one-second timeout contract.
check "a slow restore times out and succeeds (cold import) without waiting for the download" \
  'PATH="$tmp/bin:$PATH" TASK_CACHE=slow-task-cache TASK_CACHE_TIMEOUT=1 PROJECT="$proj" timeout -k 5 60 bash "$script" cache-restore 2>"$tmp/err"'
check "the timeout is logged" 'grep -qxF "[linux-unity] cache restore timed out; cold import" "$tmp/err"'
check "a timed-out restore leaves no partial Library/ or download dir" \
  '[ ! -e "$proj/Library" ] && ! ls -d "$proj"/.task-cache.* >/dev/null 2>&1'
printf '#!/bin/sh\nexit 3\n' > "$tmp/bin/miss-task-cache"; chmod +x "$tmp/bin/miss-task-cache"
check "a cache miss logs a cold import and succeeds" \
  'PATH="$tmp/bin:$PATH" TASK_CACHE=miss-task-cache PROJECT="$proj" bash "$script" cache-restore 2>"$tmp/err" && grep -q "cache restore failed (exit 3); cold import" "$tmp/err"'
mkdir -p "$proj/Library/kept"
check "a failed restore keeps a Library/ that existed before" \
  'PATH="$tmp/bin:$PATH" TASK_CACHE=miss-task-cache PROJECT="$proj" bash "$script" cache-restore 2>/dev/null && [ -d "$proj/Library/kept" ]'
rm -rf "$proj/Library"

# return: "Ulf license file not found" (nothing to give back) is success; other failures are not.
lcdir="$tmp/unity/Editor/Data/Resources/Licensing/Client"; mkdir -p "$lcdir"
printf '#!/bin/sh\necho "$FAKE_LC_OUT"; exit 1\n' > "$lcdir/Unity.Licensing.Client"; chmod +x "$lcdir/Unity.Licensing.Client"
# Fake curl: any hub call is logged (the check below wants none). The real checkout's seat marker must not change.
printf '#!/bin/sh\necho "$*" >> "%s/curl-calls"\necho 200\n' "$tmp" > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
real_marker="$(cd "$(dirname "$script")/../.." && pwd)/build/unity-seat.held"
marker_sum() { cksum 2>/dev/null < "$real_marker" || echo absent; }
marker_before="$(marker_sum)"
ret() { echo fake > "$ULF"; PATH="$tmp/bin:$PATH" UNITY_ROOT="$tmp/unity" UNITY_USERNAME=u UNITY_PASSWORD=p FAKE_LC_OUT="$1" bash "$script" return 2>/dev/null; }
check "return: Ulf license file not found is success" 'ret "[Licensing::Client] Error: Ulf license file not found"'
check "return: other errors still fail" '! ret "Error: network down"'
check "return never calls the hub nor touches the checkout's seat marker" \
  '[ ! -e "$tmp/curl-calls" ] && [ "$(marker_sum)" = "$marker_before" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
