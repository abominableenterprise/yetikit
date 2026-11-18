#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android cache fallback, partial restore and save recovery. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-cache-save.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-cache.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-cache.sh"

rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk with an Android miss falls back to the editor cache, then saves under the Android key" \
  'TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && [ "$(tr "\n" " " < "$tmp/cache-calls")" = "restore $ka restore $k save $ka " ] && grep -q "apk: cache: editor fallback" "$tmp/err"'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk: restore exit 3 cleans partial cache, imports cold, then saves Android cache" \
  'TASK_CACHE=fake-cache FAKE_PARTIAL=1 lu apk && grep -q "cache restore failed (exit 3); cold import" "$tmp/err" && grep -q "apk: cache: cold import" "$tmp/err" && [ ! -e "$proj/Library/partial" ] && [ ! -e "$proj/.task-cache.partial" ] && [ "$(tr "\n" " " < "$tmp/cache-calls")" = "restore $ka restore $k save $ka " ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "the cold save leaves Library/Bee out of the cache and puts it back afterwards" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p Library/Bee && echo x > Library/Bee/obj" TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && grep -qx "save $ka nobee" "$tmp/cache-bee" && [ -f "$proj/Library/Bee/obj" ] && [ ! -e "$proj/Temp/apk-bee-aside" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "a failed cold save still puts Library/Bee back" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p Library/Bee && echo x > Library/Bee/obj" FAKE_SAVE_RC=1 TASK_CACHE=fake-cache FAKE_HIT="$k" lu apk && grep -q "cache-save failed" "$tmp/err" && [ -f "$proj/Library/Bee/obj" ] && [ ! -e "$proj/Temp/apk-bee-aside" ]'

real_mv="$(command -v mv)"
export REAL_MV="$real_mv"
cat > "$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
from="${@: -2:1}"
case "${FAKE_MOVE_FAIL:-}:$from" in
  aside:*/Library/Bee|restore:*/Temp/apk-bee-aside) exit 42 ;;
  after-aside:*/Library/Bee) "$REAL_MV" "$@" && exit 42; exit 1 ;;
esac
exec "$REAL_MV" "$@"
EOF
chmod +x "$tmp/bin/mv"
new_bee='mkdir -p Library/Bee && echo new > Library/Bee/obj'
for direction in aside after-aside restore; do
  rm -rf "$proj/Library" "$proj/Temp"; : > "$tmp/cache-calls"
  rc=0
  FAKE_MUTATE="$FAKE_MUTATE; $new_bee" FAKE_MOVE_FAIL="$direction" TASK_CACHE=fake-cache lu apk || rc=$?
  if [ "$direction" != restore ]; then
    check "move-out failure ($direction) fails apk, keeps Bee, and skips cache save" \
      '[ "$rc" = 42 ] && grep -qx new "$proj/Library/Bee/obj" && [ ! -e "$proj/Temp/apk-bee-aside" ] && ! grep -q "^save " "$tmp/cache-calls"'
  else
    check "move-back failure fails apk and leaves Bee in the aside" \
      '[ "$rc" = 42 ] && [ -f "$proj/Temp/apk-bee-aside/obj" ] && [ ! -e "$proj/Library/Bee" ] && grep -q "^save " "$tmp/cache-calls"'
  fi
done

rm -rf "$proj/Library" "$proj/Temp"; : > "$tmp/cache-calls"
mkdir -p "$proj/Temp/apk-bee-aside"
echo old > "$proj/Temp/apk-bee-aside/obj"
rc=0
FAKE_MUTATE="$FAKE_MUTATE; $new_bee" TASK_CACHE=fake-cache lu apk || rc=$?
check "a pre-existing aside and the new Bee cache both survive" \
  '[ "$rc" != 0 ] && grep -qx old "$proj/Temp/apk-bee-aside/obj" && grep -qx new "$proj/Library/Bee/obj" && ! grep -q "^save " "$tmp/cache-calls"'

rm -rf "$proj/Library" "$proj/Temp"
gate="$tmp/save-gate"
mkfifo "$gate"
FAKE_MUTATE="$FAKE_MUTATE; $new_bee" FAKE_SAVE_GATE="$gate" TASK_CACHE=fake-cache bash "$script" apk 2>"$tmp/err" &
wrapper=$!
deadline=$((SECONDS + 10))
while [ ! -s "$gate.ready" ] && kill -0 "$wrapper" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.02; done
ready=0
if [ -s "$gate.ready" ] && [ -f "$proj/Temp/apk-bee-aside/obj" ]; then ready=1; fi
kill -TERM "$wrapper" 2>/dev/null || :
rc=0; wait "$wrapper" || rc=$?
check "wrapper-only TERM drains the blocked save and restores Bee" \
  '[ "$ready" = 1 ] && [ "$rc" = 143 ] && [ ! -e "$gate.finished" ] && grep -qx new "$proj/Library/Bee/obj" && [ ! -e "$proj/Temp/apk-bee-aside" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
