#!/usr/bin/env bash
# Exercises a sandbox-local pidfile fallback also scanned by stop.
# Tests `linux-unity.sh stop`: it kills the editor run (script, xvfb-run, Xvfb, editor) this script started, from the
# pidfile it writes under $OUT_DIR (or /tmp), and nothing else. Fake editor and Xvfb; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-stop.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"
fails=0
proj="$tmp/proj"; mkdir -p "$proj/Temp"
. "$(dirname "$0")/lib/fake-unity.sh"
bystander=""
# The bystander's sleep is its child: kill both, so no stray process keeps the caller's pipe open.
trap '[ -z "$bystander" ] || kill $(ps -o pid= --ppid "$bystander") "$bystander" 2>/dev/null || true; rm -rf "$tmp"' EXIT
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
# Wait for observed readiness with scheduling headroom.
wait_for() { ship_wait_until test -s "$1"; }

# An unrelated "Unity" process (same name as the editor, not started by the script): stop must leave it alone.
cp "$tmp/unity/Editor/Unity" "$tmp/Unity"
FAKE_SLEEP=300 FAKE_TMP="$tmp/other" bash -c 'mkdir -p "$FAKE_TMP"; exec "$0"' "$tmp/Unity" >/dev/null 2>&1 & bystander=$!

# --- a running test pass -------------------------------------------------------------------------------------------------
FAKE_XVFB=1 FAKE_SLEEP=300 bash "$script" test editmode >/dev/null 2>&1 & runner=$!
wait_for "$tmp/unity.pid"; wait_for "$tmp/xvfb.pid"
editor="$(cat "$tmp/unity.pid")"; xvfb="$(cat "$tmp/xvfb.pid")"
check "the run writes a pidfile under \$OUT_DIR naming the script's pid" \
  '[ -f "$OUT_DIR/linux-unity.pid" ] && [ "$(cut -d" " -f1 "$OUT_DIR/linux-unity.pid")" = "$runner" ]'
check "the editor and the fake Xvfb are running" 'alive "$editor" && alive "$xvfb"'
: > "$tmp/shm/udsMem1"; : > "$proj/Temp/UnityLockfile"
rc=0; bash "$script" stop 2>"$tmp/err" || rc=$?
wait "$runner" 2>/dev/null || true
check "stop exits 0" '[ "$rc" = 0 ]'
check "stop killed the editor, Xvfb and the script" '! alive "$editor" && ! alive "$xvfb" && ! alive "$runner"'
check "stop logs each process it kills" 'grep -q "stop: killing $editor" "$tmp/err" && grep -q "stop: killing $xvfb" "$tmp/err"'
check "stop removes the pidfile, the shared memory and the lockfile" \
  '[ ! -f "$OUT_DIR/linux-unity.pid" ] && [ ! -e "$tmp/shm/udsMem1" ] && [ ! -e "$proj/Temp/UnityLockfile" ]'
check "the second pass never started" '[ "$(wc -l < "$tmp/runs")" = 1 ]'
check "an unrelated Unity process is left alone" 'alive "$bystander"'

# --- nothing running, stale pidfile, a normal run ------------------------------------------------------------------------
rc=0; bash "$script" stop 2>"$tmp/err" || rc=$?
check "stop with no pidfile: exit 0, says nothing is running" '[ "$rc" = 0 ] && grep -q "nothing this script started is running" "$tmp/err"'
echo "$bystander 12345" > "$OUT_DIR/linux-unity.pid"
bash "$script" stop 2>"$tmp/err"
check "a pidfile whose pid now belongs to another process (start time differs) kills nothing" \
  'alive "$bystander" && grep -q "stale pidfile removed" "$tmp/err" && [ ! -f "$OUT_DIR/linux-unity.pid" ]'
rm -f "$tmp/runs"; EDITMODE_GFX=0 bash "$script" test editmode 2>/dev/null
check "a finished run removes its pidfile" '[ -s "$tmp/runs" ] && [ ! -f "$OUT_DIR/linux-unity.pid" ]'
# A pidfile directory that cannot be created (a file is in the way; chmod would not stop root).
: > "$tmp/notadir"; rm -f "$PIDFILE_FALLBACK"
FAKE_SLEEP=300 PIDFILE="$tmp/notadir/sub/linux-unity.pid" bash "$script" open >/dev/null 2>&1 & runner=$!
fallback="$PIDFILE_FALLBACK"
check "a pidfile directory that cannot be created uses the configured fallback" 'wait_for "$fallback" && [ "$(cut -d" " -f1 "$fallback")" = "$runner" ]'
PIDFILE="$tmp/notadir/sub/linux-unity.pid" bash "$script" stop 2>"$tmp/err"; wait "$runner" 2>/dev/null || true
check "stop finds and removes the configured fallback pidfile" '! alive "$runner" && [ ! -f "$fallback" ]'
check "a finished run cleans up the configured fallback pidfile too" \
  'PIDFILE="$tmp/notadir/sub/linux-unity.pid" bash "$script" open 2>/dev/null && [ ! -f "$fallback" ]'

# An existing read-only primary directory must not prevent scanning the fallback.
# Root otherwise bypasses mode bits; drop only those DAC capabilities for this case.
readonly_shell=(bash)
if [ "$(id -u)" = 0 ]; then
  readonly_shell=(setpriv --bounding-set=-dac_override,-dac_read_search bash)
fi
mkdir "$tmp/readonly"; chmod 555 "$tmp/readonly"
FAKE_SLEEP=300 PIDFILE="$tmp/readonly/linux-unity.pid" "${readonly_shell[@]}" "$script" open >/dev/null 2>&1 & runner=$!
check "an existing read-only primary directory selects the fallback" 'wait_for "$fallback" && [ "$(cut -d" " -f1 "$fallback")" = "$runner" ]'
rc=0
PIDFILE="$tmp/readonly/linux-unity.pid" "${readonly_shell[@]}" "$script" stop 2>"$tmp/err" || rc=$?
check "stop skips an unopenable primary lock and stops the fallback run" '[ "$rc" = 0 ] && ! alive "$runner" && [ ! -f "$fallback" ]'
# Reap the fixture even on an unfixed script, without waiting for its 300-second sleep.
if alive "$runner"; then PIDFILE="$fallback" bash "$script" stop 2>/dev/null; fi
wait "$runner" 2>/dev/null || true
chmod 755 "$tmp/readonly"

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

# #180 review: an editor that forks on TERM, inside `timeout`'s own process group, in a run piped into tee (no setsid,
# no group): the late child carries the run's marker and dies; the pipeline peer is not signalled.
mkdir -p "$tmp/unity2/Editor"
printf '#!/bin/sh\necho $$ > "$FAKE_TMP/late.pid"; exec sleep 300 >/dev/null 2>&1\n' > "$tmp/bin/late-child"
cat > "$tmp/unity2/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
trap 'late-child & wait' TERM
echo $$ > "$FAKE_TMP/unity2.pid"; while :; do sleep 0.2; done
EOF
chmod +x "$tmp/unity2/Editor/Unity" "$tmp/bin/late-child"; rm -f "$tmp/late.pid" "$tmp/unity2.pid"
( UNITY_ROOT="$tmp/unity2" bash "$script" open 2>&1 | { echo $BASHPID > "$tmp/tee.pid"; exec tee "$tmp/tee.log" >/dev/null; } ) &
pipe=$!
wait_for "$tmp/unity2.pid"; wait_for "$tmp/tee.pid"; runner="$(cut -d" " -f1 "$OUT_DIR/linux-unity.pid")"
bash "$script" stop 2>"$tmp/err"; wait "$pipe" 2>/dev/null || true
late="$(cat "$tmp/late.pid" 2>/dev/null || true)"
check "a child the editor forks on TERM (in timeout's process group) is killed too" \
  '[ -n "$late" ] && ! alive "$late" && ! alive "$(cat "$tmp/unity2.pid")" && ! alive "$runner"'
[ -z "$late" ] || ! alive "$late" || kill -9 "$late"
check "a pipeline peer (| tee) is not killed: it ends on EOF with the log" \
  'grep -q "\[linux-unity\]" "$tmp/tee.log" && ! grep -q "stop: killing $(cat "$tmp/tee.pid")" "$tmp/err"'

# #180 review (cn-1d5388e628r): marked() lists pid:start, and stop re-checks the start time and this run's marker right
# before each KILL, so a pid reused between the listing and the KILL survives. marked is stubbed (the script sourced)
# to also list a process with a stale start time and one with the right start time but no marker; real marked ones die.
proc_start() { local s; s="$(cat "/proc/$1/stat")"; set -- ${s##*) }; echo "${20}"; }
sleep 300 & run=$!; run_id="$run:$(proc_start "$run")"
echo "${run_id/:/ }" > "$OUT_DIR/linux-unity.pid"
LINUX_UNITY_RUN="$run_id" sleep 300 & mark1=$!
LINUX_UNITY_RUN="$run_id" sleep 300 & mark2=$!
sleep 300 & stale=$!; sleep 300 & unmarked=$!
ship_wait_until grep -qzx "LINUX_UNITY_RUN=$run_id" "/proc/$mark1/environ"
ship_wait_until grep -qzx "LINUX_UNITY_RUN=$run_id" "/proc/$mark2/environ"
STALE="$stale:1" UNMARKED="$unmarked:$(proc_start "$unmarked")" bash -c '
  . "$1"; eval "real_$(declare -f marked)"
  # In the format the script lists (bare pids before the fix, so this fails on the old script).
  declare -F same_proc >/dev/null || { STALE="${STALE%%:*}"; UNMARKED="${UNMARKED%%:*}"; }
  marked() { real_marked "$@"; echo "$STALE"; echo "$UNMARKED"; }
  cmd_stop' _ "$script" 2>"$tmp/err"
for i in $(seq 50); do alive "$run" || alive "$mark1" || alive "$mark2" || break; sleep 0.1; done
check "stop KILLs every real marked process (start time and marker match)" \
  '! alive "$run" && ! alive "$mark1" && ! alive "$mark2"'
check "a marked entry whose start time no longer matches (pid reused) is not killed" 'alive "$stale"'
check "a marked entry whose process no longer carries the run's marker is not killed" 'alive "$unmarked"'
{ kill -9 "$run" "$mark1" "$mark2" "$stale" "$unmarked"; wait "$run" "$mark1" "$mark2" "$stale" "$unmarked"; } 2>/dev/null || true

check "the script never runs pkill (comments aside)" '! grep -v "^[[:space:]]*#" "$script" | grep -q pkill'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
