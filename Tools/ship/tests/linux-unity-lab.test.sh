#!/usr/bin/env bash
# Tests that `linux-unity.sh lab` runs TeleportLabBuilder.Run (and only it) with its own log, and fails loudly when the
# builder fails. Uses a stub editor and a temp project.
# Run: bash Tools/ship/tests/linux-unity-lab.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shm"
export SHM_DIR="$tmp/shm"   # Never clean the host's /dev/shm.
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

proj="$tmp/proj"; mkdir -p "$proj/Assets" "$tmp/unity/Editor" "$tmp/bin"
. "$(dirname "$0")/lib/fixture.sh"
ship_fixture "$proj"
cat > "$tmp/unity/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -executeMethod) m="$2"; shift ;; -logFile) l="$2"; shift ;; esac; shift
done
echo "ran $m" > "$l"
echo "$m" >> "$(dirname "$l")/methods"
[ -z "${STUB_FAIL:-}" ]
EOF
chmod +x "$tmp/unity/Editor/Unity"
printf '<root><License id="Terms"><StopDate Value="" /></License><Signature>x</Signature></root>\n' > "$tmp/ulf"
printf '#!/usr/bin/env bash\n[ "$1" = -a ] && shift\n[ "$1" = -s ] && shift 2\nexec "$@"\n' > "$tmp/bin/xvfb-run"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/nohup"
chmod +x "$tmp/bin/xvfb-run" "$tmp/bin/nohup"
unset THEROBOTS_HUB_URL THEROBOTS_TASK_ID THEROBOTS_TASK_TOKEN UNITY_RETURN_ON_EXIT
export PATH="$tmp/bin:$PATH" UNITY_USERNAME=u UNITY_PASSWORD=p
run() { PROJECT="$proj" UNITY_ROOT="$tmp/unity" ULF="$tmp/ulf" OUT_DIR="$tmp/out" bash "$script" lab; }

rc=0; run >"$tmp/out.txt" 2>&1 || rc=$?
check "lab succeeds" '[ "$rc" = 0 ]'
check "lab runs only TeleportLabBuilder.Run" \
  '[ "$(cat "$tmp/out/methods")" = ExampleGame.Lab.Editor.TeleportLabBuilder.Run ]'
check "lab logs to scene-lab.log" 'grep -q TeleportLabBuilder "$tmp/out/scene-lab.log"'
check "lab says it rebuilt" 'grep -q "lab rebuilt" "$tmp/out.txt"'

rc=0; STUB_FAIL=1 run >"$tmp/out.txt" 2>&1 || rc=$?
check "a failed build fails the command" '[ "$rc" != 0 ] && grep -q "TeleportLabBuilder.Run failed" "$tmp/out.txt"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
