#!/usr/bin/env bash
# TERM only the wrapper, never its process group. Leave a TERM-ignoring worker
# gated so success requires both an interruptible wait and escalation.
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-apk-fixture.sh"
cat > "$tmp/bin/blocked" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
if [ "${1:-}" = restore ]; then mkdir -p Library .task-cache.partial; fi
printf '%s\n' "$$" > "$FAKE_TMP/blocked.pid"
exec /bin/sleep 120
EOF
cp "$tmp/bin/blocked" "$tmp/bin/crane"
chmod +x "$tmp/bin/blocked" "$tmp/bin/crane"
run_pid='' worker=''
cleanup() {
  for pid in "$worker" "$run_pid"; do [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT
live() { local s; { read -r s < "/proc/$1/stat"; } 2>/dev/null && [[ "${s##*) }" != 'Z '* ]]; }
run_case() {
  local signal="$1" deadline rc=0 cmd="$2"; shift 2
  rm -f "$tmp/blocked.pid"
  env "$@" bash "$script" "$cmd" ${setup_flag:+"$setup_flag"} > "$tmp/run.log" 2>&1 & run_pid=$!
  worker="$(ship_wait_for_pid "$tmp/blocked.pid")"
  if [ "$signal" = stop ]; then
    check 'standalone setup publishes the wrapper PID' \
      '[ -f "$OUT_DIR/linux-unity.pid" ] && read -r owner _ < "$OUT_DIR/linux-unity.pid" && [ "$owner" = "$run_pid" ]'
    check 'stop finds and signals the setup worker' \
      'bash "$script" stop > "$tmp/stop.log" 2>&1 && grep -qF "stop: killing $worker " "$tmp/stop.log"'
  else
    kill -TERM "$run_pid"
  fi
  deadline=$((SECONDS + 8))
  while live "$run_pid" && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
  check "$cmd ($signal): wrapper exits promptly with no live worker" '! live "$run_pid" && ! live "$worker"'
  if live "$run_pid" || live "$worker"; then
    kill -KILL "$worker" "$run_pid" 2>/dev/null || true
  fi
  wait "$run_pid" 2>/dev/null || rc=$?
  if [ "$signal" = TERM ]; then
    check "$cmd: wrapper reports TERM" '[ "$rc" = 143 ]'
  fi
  check "$cmd: wrapper ownership record is gone" '[ ! -e "$OUT_DIR/linux-unity.pid" ]'
  worker='' run_pid=''
}
setup_flag=''
mkdir -p "$proj/Library"
run_case TERM open FAKE_MUTATE='exec blocked'
apk_module
run_case TERM apk FAKE_MUTATE='exec blocked'
run_case TERM cache-save TASK_CACHE=blocked
rm -rf "$proj/Library"
run_case TERM cache-restore TASK_CACHE=blocked
check 'cancelled cold restore discards partial Library and download' \
  '[ ! -e "$proj/Library" ] && [ ! -e "$proj/.task-cache.partial" ]'
setup_flag=--no-creds
for signal in TERM stop; do
  run_case "$signal" setup UNITY_ROOT="$tmp/new-editor"
  check "setup ($signal): no partial install or extraction stage remains" \
    '[ ! -e "$tmp/new-editor" ] && ! compgen -G "$tmp/.unity-extract.*"'
done
[ "$fails" = 0 ]
