#!/usr/bin/env bash
# Exercise the real timeout wrapper with a fake editor that receives SIGKILL.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-timeout-fixture.sh"
export UNITY_CGROUP_PROC="$tmp/proc" FAKE_MEMORY_EVENTS="$tmp/cgroup/worker/memory.events"
mkdir -p "$UNITY_CGROUP_PROC" "${FAKE_MEMORY_EVENTS%/*}"
printf '0::/slice/worker\n' > "$UNITY_CGROUP_PROC/cgroup"
printf '40 39 0:32 /slice %s rw - cgroup2 cgroup rw\n' "$tmp/cgroup" > "$UNITY_CGROUP_PROC/mountinfo"
printf 'oom 7\noom_kill 3\n' > "$FAKE_MEMORY_EVENTS"
# A readable mount-root file is not the editor's nested cgroup.
printf 'oom 12\noom_kill 11\n' > "$tmp/cgroup/memory.events"
cat > "$UNITY_ROOT/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
if [ -f "$FAKE_MEMORY_EVENTS" ]; then
  printf 'oom 8\noom_kill 4\n' > "$FAKE_MEMORY_EVENTS"
fi
kill -KILL "$$"
EOF

run UNITY_TIMEOUT=0 EDITMODE_GFX=0 bash "$script" test editmode
check 'actual SIGKILL preserves status and reports the cgroup counters and changes' \
  '[ "$rc" = 137 ] && grep -qF "killed (SIGKILL)" "$tmp/err" && grep -qF "cgroup memory.events: oom=8 (+1) oom_kill=4 (+1)" "$tmp/err"'

rm -f "$FAKE_MEMORY_EVENTS"
run UNITY_TIMEOUT=0 EDITMODE_GFX=0 bash "$script" test editmode
check 'missing memory.events does not break the SIGKILL diagnosis or borrow the mount root counters' \
  '[ "$rc" = 137 ] && grep -qF "killed (SIGKILL)" "$tmp/err" && grep -qF "cgroup memory.events unavailable" "$tmp/err" && ! grep -qF "oom_kill=" "$tmp/err"'

[ "$fails" = 0 ] && echo 'all passed' || { echo "$fails failed"; exit 1; }
