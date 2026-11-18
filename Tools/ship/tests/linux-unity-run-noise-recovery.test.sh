#!/usr/bin/env bash
# Recover open/APK noise after a real Git index lock held by a synthetic editor.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-apk-cache.sh"
cd "$proj"
file=ProjectSettings/TimeManager.asset
kept=ProjectSettings/Kept.txt
printf 'TimeManager:\n  Fixed Timestep: 0.02\n' > "$file"
echo base > "$kept"
commit 'tracked settings'
export NOISE_GIT_TRIES=2 NOISE_GIT_DELAY=0 TASK_CACHE=fake-cache
for command in open apk; do
  rm -rf Library "$OUT_DIR"
  git restore -- "$file" "$kept"
  echo pre-run > "$kept"
  mutate='sed -i s/0.02/0.020000001/ ProjectSettings/TimeManager.asset; : > .git/index.lock'
  key="$k"
  if [ "$command" = apk ]; then
    key="$ka"
    mutate="$FAKE_MUTATE; $mutate; echo '[WorldBuild] synthetic build' >> \"\$OUT_DIR/apk.log\""
  fi
  rc=0
  FAKE_MUTATE="$mutate" lu "$command" || rc=$?
  check "$command: cleanup failure is distinct and preserves the lock" \
    '[ "$rc" = 3 ] && grep -qF "noise revert failed (git lock)" "$tmp/err" && [ -f .git/index.lock ]'
  check "$command: the cold cache save was attempted" 'grep -qxF "save $key" "$tmp/cache-calls"'
  if [ "$command" = apk ]; then
    check 'APK diagnostics and artifact report survive' \
      'grep -qF "[WorldBuild] synthetic build" "$tmp/err" && grep -qF "apk: size 3 bytes" "$tmp/err" && grep -qF "apk: sha256 " "$tmp/err"'
  else
    check 'open reports successful compilation' 'grep -qF "project opened and compiled" "$tmp/err"'
  fi
  check "$command: snapshot preserves only the preexisting edit" \
    '[ -f "$OUT_DIR/noise-before.txt" ] && [ "$(< "$OUT_DIR/noise-before.txt")" = "$kept" ]'
  rm .git/index.lock
  recovery="$(sed -n 's/.*by hand (from .*): //p' "$tmp/err")"
  check "$command: advertised recovery cleans only run noise" \
    '[[ "$recovery" == Tools/ship/scene-noise.sh\ --run\ * ]] && eval "$recovery" && git diff --quiet -- "$file" && [ "$(< "$kept")" = pre-run ]'
done
[ "$fails" = 0 ]
