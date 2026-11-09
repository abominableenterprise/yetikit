#!/usr/bin/env bash
# Stop late marked children without killing pipeline peers or reused/unmarked PIDs.
# Synthetic editor/process fixtures only; never runs Unity.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-stop-fixture.sh"

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
