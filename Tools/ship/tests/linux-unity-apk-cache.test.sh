#!/usr/bin/env bash
# test-all: slow linux-unity.sh android.sh
# Android Library cache keys, restores, saves and build-scratch cleanup. Uses a fake editor; never runs Unity.
# Run: bash Tools/ship/tests/linux-unity-apk-cache.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-apk-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-apk-fixture.sh"
apk_module

# --- Android Library cache ------------------------------------------------------------------------------------------
cat > "$tmp/bin/fake-cache" <<EOF
#!/bin/sh
echo "\$1 \$2" >> "$tmp/cache-calls"
case "\$1" in restore) if [ "\$2" = "\${FAKE_HIT:-}" ]; then mkdir -p Library/hit; [ "\${FAKE_WARM_RESTORE:-0}" = 0 ] || mkdir -p Library/Bee/Android; exit 0; fi
  if [ "\${FAKE_PARTIAL:-0}" = 1 ]; then mkdir -p Library .task-cache.partial; : > Library/partial; fi; exit 3 ;; esac
[ "\$1" = save ] && { [ -e Library/Bee ] || echo "\$1 \$2 nobee" >> "$tmp/cache-bee"; exit "\${FAKE_SAVE_RC:-0}"; }
EOF
chmod +x "$tmp/bin/fake-cache"
k="$(bash "$script" cache-key)"; ka="$(bash "$script" cache-key android)"
check "cache-key android is a different bare 64-hex key" '[[ "$ka" =~ ^[0-9a-f]{64}$ ]] && [ "$ka" != "$k" ]'
check "cache-key (no argument) is unchanged by the android variant" \
  '[ "$k" = "$({ cat "$proj/Packages/manifest.json" "$proj/Packages/packages-lock.json" "$proj/ProjectSettings/ProjectVersion.txt"; printf 6000.6.6f1; } | sha256sum | cut -c1-64)" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "apk with no Library/ and an Android cache hit restores it and saves nothing" \
  'TASK_CACHE=fake-cache FAKE_HIT="$ka" lu apk && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ] && grep -q "apk: cache: Android hit" "$tmp/err"'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"; : > "$tmp/runs"
check "apk: warm Android restore passes post-restore disk check and starts the editor" \
  'TASK_CACHE=fake-cache FAKE_HIT="$ka" FAKE_WARM_RESTORE=1 FAKE_FREE_GB=10 FAKE_DISK_MARKER="$proj/Library/hit" FAKE_RESTORE_FREE_GB=4 lu apk && grep -q "need 4 GB, warm: Library/Bee/Android" "$tmp/err" && [ "$(wc -l < "$tmp/runs")" = 1 ] && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"; : > "$tmp/runs"
check "apk: restored Library crosses cold threshold: fail post-restore before editor" \
  '! TASK_CACHE=fake-cache FAKE_HIT="$ka" FAKE_FREE_GB=10 FAKE_DISK_MARKER="$proj/Library/hit" FAKE_RESTORE_FREE_GB=9 lu apk && grep -q "post-restore.*only 9 GB free.*need 10 GB" "$tmp/err" && [ ! -s "$tmp/runs" ] && [ "$(cat "$tmp/cache-calls")" = "restore $ka" ] && [ ! -e "$OUT_DIR/linux-unity.pid" ]'
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
check "apk removes the Android build scratch .utmp/ from the project root" \
  'FAKE_MUTATE="$FAKE_MUTATE; mkdir -p .utmp/Debug" lu apk && [ ! -e "$proj/.utmp" ]'
rm -rf "$proj/Library"; : > "$tmp/cache-calls"
check "a failed cold build saves no cache" \
  '! TASK_CACHE=fake-cache FAKE_UNITY_RC=1 lu apk && ! grep -q "^save" "$tmp/cache-calls"'
: > "$tmp/cache-calls"
check "apk with a Library/ never touches the cache" 'mkdir -p "$proj/Library" && TASK_CACHE=fake-cache lu apk && [ ! -s "$tmp/cache-calls" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
