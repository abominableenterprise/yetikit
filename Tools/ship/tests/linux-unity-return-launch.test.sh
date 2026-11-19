#!/usr/bin/env bash
# Exercise the validation/launch window with two wrappers and a shared ULF.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-seat-fixture.sh"

# Pause the editor's ULF validation until return either contends for the same
# lock or finishes. A failed unlink leaves the stale ULF structurally valid.
cat > "$tmp/bin/perl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -0777 ] && [ "${PAUSE_VALIDATION:-0}" = 1 ] && [ ! -e "$FAKE_TMP/validating" ]; then
  touch "$FAKE_TMP/validating"
  deadline=$((SECONDS + 60))
  until [ -e "$FAKE_TMP/contended" ] || [ -e "$FAKE_TMP/return-done" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 99
    /bin/sleep 0.02
  done
fi
exec /usr/bin/perl "$@"
EOF
cat > "$tmp/bin/rm" <<'EOF'
#!/usr/bin/env bash
if [ "${FAIL_ULF_UNLINK:-0}" = 1 ] && [ "${*: -1}" = "$FAKE_TMP/ulf" ]; then exit 1; fi
exec /bin/rm "$@"
EOF
cat > "$tmp/bin/profile-cli" <<'EOF'
#!/usr/bin/env bash
if [ ! -e "$ULF.returning" ] && ! /usr/bin/flock -n "$ULF.lock" true; then echo safe > "$FAKE_TMP/launch"; fi
while [ "$#" -gt 0 ]; do
  case "$1" in --output-path) out="$2"; shift ;; -l) log="$2"; shift ;; esac
  shift
done
mkdir -p "$(dirname "$out")"
printf 'synthetic apk\n' > "$out"
printf 'synthetic build\n' > "$log"
EOF
chmod +x "$tmp/bin/"{perl,rm,profile-cli}
mkdir -p "$UNITY_ROOT/Editor/Data/PlaybackEngines/AndroidPlayer/"{SDK,NDK} "$proj/Library"
jq '.build = {profile:"TestProfile", cli:"profile-cli", apkPath:"Builds/Profile.apk"}' \
  "$proj/yetikit.json" > "$tmp/config"
mv "$tmp/config" "$proj/yetikit.json"
commit config
export APK_SWAP_GB=0 APK_MIN_FREE_GB=0 APK_MIN_FREE_GB_WARM=0
ln -s "$ULF" "$tmp/alias.ulf"

for route in open apk; do
  reset 200
  rm -rf "$ULF.returning"
  rm -f "$tmp/validating" "$tmp/contended" "$tmp/return-done" "$tmp/launch"
  printf '%s\n' "$good_ulf" > "$ULF"
  SHIP_READINESS_RUN="$tmp" UNITY_USERNAME=u UNITY_PASSWORD=p PAUSE_VALIDATION=1 \
    FAKE_MUTATE='if [ ! -e "$ULF.returning" ] && ! /usr/bin/flock -n "$ULF.lock" true; then echo safe > "$FAKE_TMP/launch"; fi' \
    bash "$script" "$route" > "$tmp/editor-log" 2>&1 & readiness_runner=$!
  if ! ship_wait_until test -f "$tmp/validating"; then
    head -60 "$tmp/editor-log" >&2
    exit 1
  fi
  # Use a different checkout's OUT_DIR and a symlink, so the editor cleanup
  # and pidfile locks cannot accidentally serve as the licence handoff.
  (
    status=0
    ULF="$tmp/alias.ulf" OUT_DIR="$tmp/return-out" UNITY_USERNAME=u UNITY_PASSWORD=p \
      FAKE_LOCK_WAIT="$tmp/contended" FAIL_ULF_UNLINK=1 \
      /usr/bin/timeout -k 2 75 bash "$script" return > "$tmp/return-log" 2>&1 || status=$?
    touch "$tmp/return-done"
    exit "$status"
  ) & returning=$!; concurrent=("$returning")
  editor_rc=0; wait "$readiness_runner" || editor_rc=$?; cleanup_readiness_runner
  return_rc=0; wait "$returning" || return_rc=$?; concurrent=()
  check "$route: return waits at the shared ULF lock during authorization and launch" \
    '[ "$editor_rc" = 0 ] && [ -f "$tmp/contended" ] && [ -f "$tmp/launch" ]'
  check "$route: competing return ran and left a confirmed guard after failed unlink" \
    '[ "$return_rc" = 1 ] && [ -f "$ULF" ] && [ -f "$ULF.returning/returned" ] && grep -qx -- --return-ulf "$tmp/lc-calls"'
done
[ "$fails" = 0 ]
