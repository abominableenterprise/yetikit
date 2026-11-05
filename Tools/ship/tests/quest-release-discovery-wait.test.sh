#!/usr/bin/env bash
# Early device-discovery failures must never certify a previous successful release.
set -eu
ship="$(cd "$(dirname "$0")/.." && pwd)"
. "$ship/tests/lib/quest-release-config.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
qr_test_config "$tmp/config"
export QUEST_LOG_ROOT="$tmp/logs" QUEST_WT_ROOT="$tmp/wt" HOME="$tmp/home"
export QUEST_WAIT_GRACE=0 QUEST_WAIT_POLL=0.05
mkdir -p "$tmp/bin" "$HOME"
printf '#!/bin/sh\nprintf "List of devices attached\\n"\n[ "$DISCOVERY_COUNT" = 0 ] || printf "synthetic-one\\tdevice\\nsynthetic-two\\tdevice\\n"\n' > "$tmp/bin/adb"
chmod +x "$tmp/bin/adb"
export PATH="$tmp/bin:$PATH"
fails=0
for count in 0 2; do
  rm -rf "$QUEST_LOG_ROOT"; mkdir -p "$QUEST_LOG_ROOT/old/summary"
  old="$QUEST_LOG_ROOT/old"
  printf 'QR_RUN_DIR=%q\n' "$old" > "$QUEST_LOG_ROOT/current.env"
  echo 'install ok (/old.apk)' > "$old/summary/install"
  echo 'old successful install summary' > "$old/summary.txt"
  printf 'pid=4242\ncmd=all\nrc=0\nrun=%s\n' "$old" > "$QUEST_LOG_ROOT/last-result"
  unset QUEST_SERIAL
  export DISCOVERY_COUNT="$count"
  release_rc=0
  bash "$ship/quest-release.sh" all > "$tmp/release.out" 2>&1 & owner=$!
  wait "$owner" || release_rc=$?
  wait_rc=0
  bash "$ship/quest-release.sh" wait 1 > "$tmp/wait.out" 2>&1 || wait_rc=$?
  if [ "$release_rc" = 1 ] && [ "$wait_rc" = 1 ] \
    && grep -q 'exited 1' "$tmp/wait.out" \
    && ! grep -q 'old successful' "$tmp/wait.out" \
    && grep -q "^pid=$owner$" "$QUEST_LOG_ROOT/last-result" \
    && [ ! -e "$QUEST_LOG_ROOT/run.lock" ]; then
    echo "ok   $count discovered devices: background release and unpinned wait both fail, without stale success"
  else
    echo "FAIL $count discovered devices: release=$release_rc wait=$wait_rc"
    cat "$tmp/release.out" "$tmp/wait.out"
    fails=$((fails + 1))
  fi
done
# Even without a lock or new result, a published invocation must never consume old completion evidence.
printf '999999\n' > "$QUEST_LOG_ROOT/current-invocation"
printf 'pid=4242\ncmd=all\nrc=0\nrun=%s\n' "$old" > "$QUEST_LOG_ROOT/last-result"
wait_rc=0
bash "$ship/quest-release.sh" wait 1 > "$tmp/wait.out" 2>&1 || wait_rc=$?
if [ "$wait_rc" = 1 ] && grep -q 'without writing its result' "$tmp/wait.out" \
  && ! grep -q 'old successful' "$tmp/wait.out"; then
  echo 'ok   a published invocation without a result rejects older success'
else
  echo "FAIL published invocation without a result: wait=$wait_rc"
  cat "$tmp/wait.out"; fails=$((fails + 1))
fi
[ "$fails" = 0 ]
echo 'all passed'
