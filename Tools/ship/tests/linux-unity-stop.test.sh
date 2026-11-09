#!/usr/bin/env bash
# Stop a running editor and verify pidfile ownership, fallback and cleanup.
# Synthetic editor/process fixtures only; never runs Unity.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-stop-fixture.sh"

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

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
