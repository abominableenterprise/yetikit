#!/usr/bin/env bash
# Stop during cache restore, overlapping commands and a continuously forking process tree.
# Synthetic editor/process fixtures only; never runs Unity.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-stop-fixture.sh"

# --- before any editor runs: a slow cache restore of a cold open ---------------------------------------------------------
printf '#!/bin/sh\necho $$ > "%s/cache.pid"; exec sleep 300\n' "$tmp" > "$tmp/bin/slow-cache"; chmod +x "$tmp/bin/slow-cache"
rm -f "$tmp/runs"; rm -rf "$proj/Library"; mkdir -p "$proj/Packages" "$proj/ProjectSettings"
echo '{}' > "$proj/Packages/manifest.json"; echo '{}' > "$proj/Packages/packages-lock.json"
echo 'm_EditorVersion: 6000.6.6f1' > "$proj/ProjectSettings/ProjectVersion.txt"
TASK_CACHE=slow-cache bash "$script" open >/dev/null 2>&1 & runner=$!
wait_for "$tmp/cache.pid"; cache="$(cat "$tmp/cache.pid")"
check "the pidfile exists during the cache restore, before any editor" \
  '[ "$(cut -d" " -f1 "$OUT_DIR/linux-unity.pid")" = "$runner" ] && [ ! -e "$tmp/runs" ]'
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
check "stop during the cache restore kills the script and the restore; no editor starts" \
  '! alive "$runner" && ! alive "$cache" && grep -q "stop: killing $runner" "$tmp/err" && ! grep -q "nothing this script started" "$tmp/err" && [ ! -e "$tmp/runs" ]'
# --- #180 review: an overlapping command, a tree that keeps forking, a child that ignores TERM -------------------------
rm -f "$tmp/unity.pid"   # left by earlier cases: wait for this run's editor
FAKE_SLEEP=300 bash "$script" open >/dev/null 2>&1 & runner=$!
wait_for "$tmp/unity.pid"
rc=0; bash "$script" open --bad 2>"$tmp/err" || rc=$?
check "a second command while a run is live fails and leaves the live run's pidfile" \
  '[ "$rc" != 0 ] && { grep -qF "another run (pid $runner," "$tmp/err" || grep -qF "another Unity run owns $SHM_DIR;" "$tmp/err"; } && alive "$runner" && [ "$(cut -d" " -f1 "$OUT_DIR/linux-unity.pid")" = "$runner" ]'
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
check "stop still finds and kills that live run" '! alive "$runner" && grep -q "stop: killing $runner" "$tmp/err"'
# A cache restore that forks a new sleep every 20 ms (at most 500), and one child that ignores TERM.
cat > "$tmp/bin/fork-cache" <<EOF
#!/usr/bin/env bash
bash -c 'trap "" TERM; echo \$\$ > "$tmp/stubborn.pid"; while :; do sleep 1; done' &
for i in \$(seq 500); do sleep 300 & echo \$! >> "$tmp/forked"; sleep 0.02; done; wait
EOF
chmod +x "$tmp/bin/fork-cache"; rm -rf "$proj/Library" "$tmp/forked" "$tmp/stubborn.pid"
TASK_CACHE=fork-cache bash "$script" open >/dev/null 2>&1 & runner=$!
wait_for "$tmp/stubborn.pid"; wait_for "$tmp/forked"
bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
survivors=""; for p in $(cat "$tmp/forked") "$(cat "$tmp/stubborn.pid")"; do alive "$p" && survivors="$survivors $p"; done
[ -z "$survivors" ] || kill -9 $survivors 2>/dev/null || true
check "stop freezes the tree first: nothing the run forks while stop works survives" '! alive "$runner" && [ -z "$survivors" ]'
check "a child that ignores TERM is still killed (KILL after the start-time check)" '! alive "$(cat "$tmp/stubborn.pid")"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
