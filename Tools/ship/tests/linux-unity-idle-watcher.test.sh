#!/usr/bin/env bash
# Isolated synthetic licence lifecycle/idle regression cases.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-idle-fixture.sh"

# Real detached launcher, real sleeping watcher; another CLI command must reuse its pid, not launch a second.
rm "$tmp/bin/nohup" "$tmp/bin/sleep"
export UNITY_IDLE_RETURN_MINUTES=10
# A fresh checkout has no build directory or idle pidfile, even with a usable licence.
export OUT_DIR="$proj/build"
printf '%s\n' "$good" > "$ULF"
check 'fresh checkout has no build directory' '[ ! -d "$OUT_DIR" ]'
lu open
check 'fresh open starts the idle watcher without a missing-pidfile warning' \
  '[ "$rc" = 0 ] && ! grep -q "No such file or directory" "$tmp/log"'
watcher_ready() {
  local record
  record="$(ship_read_line "$idle_dir/unity-idle.pid")" || return 1
  read -r candidate start _ <<< "$record"
  [[ "$candidate" =~ ^[1-9][0-9]*$ && "$start" =~ ^[0-9]+$ ]]
}
ship_wait_until watcher_ready
watcher="$candidate"
lu activate
check 'detached watcher is live and reused' 'kill -0 "$watcher" && [ "$(cut -d" " -f1 "$idle_dir/unity-idle.pid")" = "$watcher" ]'
# The old watcher must retire and a real detached replacement must take over on ownership change.
THEROBOTS_TASK_ID=5632 lu activate
replacement_ready() { watcher_ready && [ "$candidate" != "$watcher" ]; }
ship_wait_until replacement_ready
replacement="$candidate"
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
