#!/usr/bin/env bash
# A synthetic editor starting during cleanup must prevent installation replacement.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"
cleanup() {
  if [ -s "$tmp/editor.pid" ]; then
    kill "$(< "$tmp/editor.pid")" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
. "$(dirname "$0")/lib/fixture.sh"
real_readlink="$(command -v readlink)"
ship_fixture "$tmp"
ship_fixture_process_view "$tmp/process-view"
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

root="$tmp/install/unity"
mkdir -p "$root/Editor" "$tmp/bin" "$tmp/shm"
cp /usr/bin/sleep "$root/Editor/Unity"
printf 'keep installation data\n' > "$root/resource"
touch "$root/.install-complete"
# This fixture is complete before setup, but has no Android module.
lc="Editor/Data/Resources/Licensing/Client"
mkdir -p "$root/$lc"
printf '#!/bin/sh\nexit 0\n' > "$root/$lc/Unity.Licensing.Client"
chmod +x "$root/$lc/Unity.Licensing.Client"

# A replacement would extract a valid Android image, making a missed refusal observable.
img="$tmp/img"
mkdir -p "$img/opt/unity/$lc" \
  "$img/opt/unity/Editor/Data/PlaybackEngines/AndroidPlayer/SDK" \
  "$img/opt/unity/Editor/Data/PlaybackEngines/AndroidPlayer/NDK"
printf '#!/bin/sh\n# Unity 6000.6.6f1\n' > "$img/opt/unity/Editor/Unity"
cp "$root/$lc/Unity.Licensing.Client" "$img/opt/unity/$lc/Unity.Licensing.Client"
chmod +x "$img/opt/unity/Editor/Unity"
cat > "$tmp/bin/crane" <<EOF
#!/bin/bash
echo crane >> "$tmp/download-calls"
tar -c -C "$img" opt/unity
EOF
for command in dpkg ldd nohup; do
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$command"
done

# The first scan sees no synthetic editor. Only cleanup's sleep opens the gate;
# wait for the executable identity before allowing cleanup to continue.
{
  printf '#!/bin/bash\nset -euo pipefail\n'
  declare -f ship_wait_until
  printf 'real_readlink=%q\n' "$real_readlink"
  cat <<'EOF'
if [ "$*" = 2 ] && [ -n "${FAKE_LATE_EDITOR_GATE:-}" ]; then
  env -u LINUX_UNITY_RUN "$UNITY_ROOT/Editor/Unity" 300 & editor=$!
  printf '%s\n' "$editor" > "$FAKE_LATE_EDITOR_GATE"
  editor_ready() { [ "$("$real_readlink" "/proc/$editor/exe" 2>/dev/null)" = "$UNITY_ROOT/Editor/Unity" ]; }
  ship_wait_until editor_ready
fi
exec /bin/sleep "$@"
EOF
} > "$tmp/bin/sleep"
# Model an editor that exits between cleanup observing it and the final privileged
# recheck. The initial privileged scan runs before the sleep fixture writes the PID.
cat > "$tmp/bin/id" <<'EOF'
#!/bin/bash
if [ "$*" = -u ]; then echo 1001; else exec /usr/bin/id "$@"; fi
EOF
{
  printf '#!/bin/bash\nset -euo pipefail\n'
  declare -f ship_wait_until
  printf 'real_readlink=%q\n' "$real_readlink"
  cat <<'EOF'
if [ "${FAKE_EXIT_BEFORE_RECHECK:-0}" = 1 ] && [ "$1" = env ] && [ -s "$FAKE_LATE_EDITOR_GATE" ]; then
  editor=$(< "$FAKE_LATE_EDITOR_GATE")
  kill "$editor"
  editor_gone() { ! "$real_readlink" "/proc/$editor/exe" >/dev/null 2>&1; }
  ship_wait_until editor_gone
fi
export FAKE_PRIVILEGED=1
exec "$@"
EOF
} > "$tmp/bin/sudo"

# Expose the late editor only to the privileged scan in the first scenario,
# and to cleanup itself in the second scenario.
cat > "$tmp/bin/readlink" <<EOF
#!/bin/bash
if [ -s "$tmp/editor.pid" ] && { [ "\${FAKE_EXIT_BEFORE_RECHECK:-0}" = 1 ] || [ "\${FAKE_PRIVILEGED:-0}" = 1 ]; }; then
  export SHIP_FIXTURE_PIDS="\$(< "$tmp/editor.pid")"
fi
exec "$tmp/process-view/readlink" "\$@"
EOF
chmod +x "$tmp/bin/"*
: > "$tmp/download-calls"
downloads_before="$(wc -l < "$tmp/download-calls")"
run_setup() {
  rc=0
  PATH="$tmp/bin:$PATH" UNITY_ROOT="$root" BIN_DIR="$tmp/bin" OUT_DIR="$tmp/logs" \
    SHM_DIR="$tmp/shm" FAKE_LATE_EDITOR_GATE="$tmp/editor.pid" FAKE_EXIT_BEFORE_RECHECK="$1" \
    bash "$script" setup --android --no-creds > "$tmp/out" 2>&1 || rc=$?
}
run_setup 0
check 'cleanup launched the editor from the installation' \
  '[ -s "$tmp/editor.pid" ]'
check 'the final privileged scan catches an editor the cleanup scan missed' \
  '[ "$rc" != 0 ] && grep -qF "cannot replace $root while Unity processes remain" "$tmp/out"'
check 'late editor remains alive and its installation is intact' \
  'kill -0 "$(< "$tmp/editor.pid")" && cmp -s /usr/bin/sleep "$root/Editor/Unity" && [ "$(< "$root/resource")" = "keep installation data" ] && [ -f "$root/.install-complete" ]'
check 'late editor refusal does not extract an image' \
  '[ "$(wc -l < "$tmp/download-calls")" = "$downloads_before" ]'

if [ -s "$tmp/editor.pid" ]; then kill "$(< "$tmp/editor.pid")" 2>/dev/null || true; fi
rm -f "$tmp/editor.pid"
run_setup 1
check 'cleanup observed an editor launched during its wait' \
  '[ -s "$tmp/editor.pid" ] && grep -qF "Unity processes remain" "$tmp/out"'
check 'cleanup refusal stops replacement even if a later scan would be clear' \
  '[ "$rc" != 0 ] && grep -qF "cleanup did not complete; refusing to replace $root" "$tmp/out" && cmp -s /usr/bin/sleep "$root/Editor/Unity" && [ "$(< "$root/resource")" = "keep installation data" ] && [ -f "$root/.install-complete" ] && [ "$(wc -l < "$tmp/download-calls")" = "$downloads_before" ]'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
