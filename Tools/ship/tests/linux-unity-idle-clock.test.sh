#!/usr/bin/env bash
# Isolated synthetic licence lifecycle/idle regression cases.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-idle-fixture.sh"

# Start without a licence, as after the successful timeout retry.
rm -f "$ULF"
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

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
