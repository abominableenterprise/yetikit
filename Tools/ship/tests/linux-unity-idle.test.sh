#!/usr/bin/env bash
# Deterministic licence lifecycle/idle tests; no Unity, real hub, or wall-clock waits.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; proj="$tmp/proj"; mkdir -p "$proj/Assets"
echo x > "$proj/Assets/a.txt"
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
git_init
good="$(cat "$ULF")"
idle_dir="$(readlink -m "$ULF").idle"
export UNITY_USERNAME=u UNITY_PASSWORD=p THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=5631 THEROBOTS_TASK_TOKEN=fake
export UNITY_IDLE_RETURN_MINUTES=1
unset UNITY_RETURN_ON_EXIT
lc="$UNITY_ROOT/Editor/Data/Resources/Licensing/Client"
mkdir -p "$lc"
cat > "$lc/Unity.Licensing.Client" <<EOF
#!/bin/bash
echo "\$1" >> "$tmp/lc-calls"
case "\$1" in
 --activate-ulf) printf '%s\n' '$good' > "\$ULF" ;;
 --return-ulf) if [ "\${FAKE_RETURN_HANG:-0}" != 0 ]; then
   [ "\$FAKE_RETURN_HANG" != 1 ] || trap '' TERM
   echo \$\$ > "$tmp/return.pid"
   bash -c 'trap "" TERM; exec /bin/sleep 300' & echo \$! > "$tmp/return-child.pid"; wait
 fi
 [ "\${FAKE_MISSING:-0}" = 0 ] || { echo 'Ulf license file not found (1404)'; exit 7; }; exit "\${FAKE_RETURN_RC:-0}" ;;
esac
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
cat >/dev/null
while [ $# -gt 0 ]; do
 case "$1" in -D) h="$2"; shift ;; -o) b="$2"; shift ;; -d) echo "$2" >> "$FAKE_TMP/hub-calls"; shift ;; esac
 shift
done
: > "$h"; echo '{"status":"acquired"}' > "$b"; printf 200
EOF
# Suppress launch for deterministic foreground watcher checks, but exercise the launch path below.
printf '#!/bin/bash\necho launch >> "$FAKE_TMP/launches"\n' > "$tmp/bin/nohup"
# Fast initial polls; defer retries beyond the outer deadline so this test
# observes exactly the first failed attempt even with slow config startup.
printf '#!/bin/bash\ncase "$1" in 5) ;; 10) exec /bin/sleep 30 ;; *) exec /bin/sleep "$@" ;; esac\n' > "$tmp/bin/sleep"
chmod +x "$lc/Unity.Licensing.Client" "$tmp/bin/"*
lu() { rc=0; bash "$script" "$@" > "$tmp/log" 2>&1 || rc=$?; }
count() { grep -c -- "$1" "$tmp/lc-calls" || true; }
rm -f "$ULF"
lu activate; lu activate
check 'two commands activate once and return zero times' '[ "$rc" = 0 ] && [ "$(count --activate-ulf)" = 1 ] && [ "$(count --return-ulf)" = 0 ]'
lu return
check 'explicit return returns/releases once' '[ "$rc" = 0 ] && [ "$(count --return-ulf)" = 1 ] && [ "$(grep -c release "$tmp/hub-calls")" = 1 ]'
lu return
check 'second return is no-op success' '[ "$rc" = 0 ] && [ "$(count --return-ulf)" = 1 ] && grep -q "return: licence already returned" "$tmp/log"'
lu activate
UNITY_RETURN_ON_EXIT=1 lu return
check 'explicit return plus EXIT opt-in returns exactly once' '[ "$rc" = 0 ] && [ "$(count --return-ulf)" = 2 ]'
# A failed explicit return must not be retried by the EXIT trap either.
lu activate
UNITY_RETURN_ON_EXIT=1 FAKE_RETURN_RC=9 lu return
check 'failed explicit return plus EXIT opt-in attempts exactly once' '[ "$rc" = 9 ] && [ "$(count --return-ulf)" = 3 ] && [ -f "$ULF" ]'
# Keep cumulative successful-return checks below independent of this deliberate failed attempt.
sed -i '$d' "$tmp/lc-calls"
lu activate
FAKE_MISSING=1 lu return
check 'client 1404 is success and releases the seat' '[ "$rc" = 0 ] && [ ! -f "$ULF" ] && [ ! -f "$OUT_DIR/unity-seat.held" ]'
lu activate
FAKE_UNITY_RC=1 lu open
check 'failed command holds licence and seat' '[ "$rc" != 0 ] && [ -f "$ULF" ] && [ -f "$OUT_DIR/unity-seat.held" ] && [ "$(count --return-ulf)" = 3 ]'
UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=1 lu open
check 'failed command with opt-in returns even a reused licence' '[ "$rc" != 0 ] && [ ! -f "$ULF" ] && [ "$(count --return-ulf)" = 4 ]'

# Bound both a TERM-resistant client and a TERM-exiting client whose child alone ignores TERM.
# Outer deadlines include validated config loading as well as the client's
# 1 s timeout + 5 s KILL grace. The 1 s production limit stays unchanged.
alive() { kill -0 "$1" 2>/dev/null && [ "$(cut -d" " -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]; }
for hang in 1 child-only; do
rm -f "$tmp/return.pid" "$tmp/return-child.pid"
lu activate
UNITY_IDLE_RETURN_MINUTES=0 UNITY_RETURN_TIMEOUT=1 FAKE_RETURN_HANG="$hang" \
  timeout -k 1 30 bash "$script" __idle-return > "$tmp/hung-watch-log" 2>&1 & hung_watcher=$!
for _ in {1..1000}; do [ -s "$tmp/return-child.pid" ] && break; /bin/sleep 0.02; done
check "idle return ($hang): hung client started while holding activity lock" '[ -s "$tmp/return-child.pid" ]'
rc=0; timeout -k 1 20 bash "$script" stop > "$tmp/stop-log" 2>&1 || rc=$?
wait "$hung_watcher" 2>/dev/null || true
check "idle return ($hang): timeout unblocks stop without deleting licence or releasing seat" \
  '[ "$rc" = 0 ] && grep -q "idle return failed" "$tmp/hung-watch-log" && [ -f "$ULF" ] && [ -f "$OUT_DIR/unity-seat.held" ]'
check "idle return ($hang): client and TERM-resistant child are killed" \
  '! alive "$(cat "$tmp/return.pid")" && ! alive "$(cat "$tmp/return-child.pid")"'
# Clean up even on the failing-first run, where the outer deadline killed the watcher, not the client.
for p in "$tmp/return.pid" "$tmp/return-child.pid"; do kill -KILL "$(cat "$p")" 2>/dev/null || true; done
rc=0; timeout -k 1 20 bash "$script" return > "$tmp/retry-log" 2>&1 || rc=$?
check "idle return ($hang): explicit retry succeeds after timeout and releases seat" \
  '[ "$rc" = 0 ] && [ ! -f "$ULF" ] && [ ! -f "$OUT_DIR/unity-seat.held" ]'
done

# Fake date/touch/sleep advance a clock by 20 s per poll. A real CLI invocation at t=40 resets activity.
real_date="$(command -v date)"; real_touch="$(command -v touch)"
cat > "$tmp/bin/date" <<EOF
#!/bin/bash
if [ "\$*" = +%s ]; then cat "$tmp/clock"; else exec "$real_date" "\$@"; fi
EOF
cat > "$tmp/bin/touch" <<EOF
#!/bin/bash
exec "$real_touch" -d "@\$(cat "$tmp/clock")" "\$@"
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/bash
n=$(($(cat "$FAKE_TMP/clock") + 20)); echo "$n" > "$FAKE_TMP/clock"
echo "$n $(grep -c -- --return-ulf "$FAKE_TMP/lc-calls")" >> "$FAKE_TMP/ticks"
if [ "$n" = 40 ] && [ "${RESET_IDLE:-0}" = 1 ]; then bash "$IDLE_TEST_SCRIPT" activate > "$FAKE_TMP/reset-log" 2>&1; fi
if [ "$n" = 40 ] && [ "${ACTIVE_IDLE:-0}" = 1 ]; then
  mkdir -p "$(readlink -m "$ULF").idle/unity-active"
  # Parent test is alive while the watcher runs, just like a long-running editor command.
  echo "$ACTIVE_START" > "$(readlink -m "$ULF").idle/unity-active/$ACTIVE_PID"
fi
if [ "$n" = 80 ] && [ "${ACTIVE_IDLE:-0}" = 1 ]; then
  rm -f "$(readlink -m "$ULF").idle/unity-active/$ACTIVE_PID"; touch "$(readlink -m "$ULF").idle/unity-activity"
fi
[ "$n" -lt 200 ] || exit 99
EOF
chmod +x "$tmp/bin/"*
export IDLE_TEST_SCRIPT="$script"
for mode in normal reset active; do
 echo 0 > "$tmp/clock"; : > "$tmp/lc-calls"; : > "$tmp/ticks"
 lu activate
 export RESET_IDLE=0 ACTIVE_IDLE=0
 [ "$mode" != reset ] || export RESET_IDLE=1
 [ "$mode" != active ] || export ACTIVE_IDLE=1
 export ACTIVE_PID=$$ ACTIVE_START="$(bash -c '. "$1"; proc_start "$2"' _ "$script" "$$")"
 bash -c '. "$1"; idle_watch' _ "$script" > "$tmp/watch-log" 2>&1
 expected=60; [ "$mode" != reset ] || expected=100; [ "$mode" != active ] || expected=140
 check "idle $mode: returns/releases only after grace, activity resets it" \
  '[ "$(tail -n1 "$tmp/ticks" | cut -d" " -f1)" = "$expected" ] && ! grep -qv " 0$" "$tmp/ticks" && [ "$(count --return-ulf)" = 1 ] && [ ! -f "$OUT_DIR/unity-seat.held" ]'
done

# Real detached launcher, real sleeping watcher; another CLI command must reuse its pid, not launch a second.
rm "$tmp/bin/nohup" "$tmp/bin/sleep" "$tmp/bin/date" "$tmp/bin/touch"
export UNITY_IDLE_RETURN_MINUTES=10
# A fresh checkout has no build directory or idle pidfile, even with a usable licence.
export OUT_DIR="$proj/build"
printf '%s\n' "$good" > "$ULF"
check 'fresh checkout has no build directory' '[ ! -d "$OUT_DIR" ]'
lu open
check 'fresh open starts the idle watcher without a missing-pidfile warning' \
  '[ "$rc" = 0 ] && ! grep -q "No such file or directory" "$tmp/log"'
for _ in {1..1000}; do [ -s "$idle_dir/unity-idle.pid" ] && break; /bin/sleep 0.02; done
read -r watcher start < "$idle_dir/unity-idle.pid"
lu activate
check 'detached watcher is live and reused' 'kill -0 "$watcher" && [ "$(cut -d" " -f1 "$idle_dir/unity-idle.pid")" = "$watcher" ]'
# The old watcher must retire and a real detached replacement must take over on ownership change.
THEROBOTS_TASK_ID=5632 lu activate
for _ in {1..1000}; do
  replacement="$(cut -d' ' -f1 "$idle_dir/unity-idle.pid" 2>/dev/null || true)"
  [ -n "$replacement" ] && [ "$replacement" != "$watcher" ] && break
  /bin/sleep 0.02
done
check 'changed ownership hands off to a live replacement watcher' \
  '[ -n "$replacement" ] && [ "$replacement" != "$watcher" ] && kill -0 "$replacement"'
kill "$watcher" 2>/dev/null || true
watcher="$replacement"
# Removing the pidfile must also be harmless to stop/return. Suppress a replacement watcher.
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/nohup"; chmod +x "$tmp/bin/nohup"
rm "$idle_dir/unity-idle.pid"
lu stop
check 'stop with no idle pidfile emits no missing-file warning' \
  '[ "$rc" = 0 ] && ! grep -q "No such file or directory" "$tmp/log"'
lu return
check 'return with no idle pidfile emits no missing-file warning' \
  '[ "$rc" = 0 ] && ! grep -q "No such file or directory" "$tmp/log"'
kill "$watcher" 2>/dev/null || true
[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
