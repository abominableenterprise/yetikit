#!/usr/bin/env bash
# Real unity()/qr_timebox wrappers, fake executable editor. Never runs Unity, git, adb or a device.
# Each fake stall self-terminates too, so the pre-fix regression fails rather than hanging the parent runner.
# shellcheck disable=SC2016 # check evaluates conditions in the test shell.
set -u
ci_dir="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Tools/ship/quest-release/common.sh
. "$ci_dir/quest-release/common.sh"
# shellcheck source=Tools/ship/quest-release/unity-steps.sh
. "$ci_dir/quest-release/unity-steps.sh"
tmp="$(mktemp -d)"
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
qr_test_build_config
cleanup() {
  local f pid
  for f in "$tmp"/run-*/editor-*.pid "$tmp"/run-*/compiler-*.pid "$tmp"/run-*/gradle-*.pid "$tmp/unrelated.pid"; do
    [ -f "$f" ] || continue
    read -r pid < "$f"
    kill -TERM "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
check() {
  if eval "$2"; then echo "ok   $1"
  else echo "FAIL $1"; [ ! -f "$tmp/output" ] || tail -n 25 "$tmp/output"; fails=$((fails + 1)); fi
}
qr_need_commit() { :; }
qr_wt() { printf '%s\n' "$tmp/build"; }
qr_android_user_home() { printf '%s\n' "$tmp/android home"; }
qr_last_installed_sha() { :; }
QR_KEYSTORE_CHECKED=1; QR_SHA=abc123456; QR_SHORT=abc123456
QR_APK_REL=out.apk; QR_APK_DIR="$tmp/apks"; QR_BUILD_TIMEOUT=30
mkdir -p "$tmp/build" "$tmp/bin"
export WATCH_TMP="$tmp" XDG_CONFIG_HOME="$tmp/xdg"
UNITY_BIN="$tmp/fake editor"
qr_editor_dir() { printf '%s\n' "$tmp/editor"; } # Version checks belong to doctor/config tests.
qr_unity_bin() { printf '%s\n' "$UNITY_BIN"; }
# Compiler and Gradle stand-ins ignore TERM, including after their editor exits. They self-expire so even
# a failing regression cannot leave long-lived workers behind. Record both generations before stalling.
cat > "$tmp/fake worker" <<'WORKER'
#!/usr/bin/env bash
role="$1"; n="$2"
printf '%s\n' "$$" > "$WATCH_RUN/$role-$n.pid"
trap '' TERM
if [ "$role" = compiler ]; then
  "$0" gradle "$n" &
fi
deadline=$((SECONDS + 20))
while [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
wait
WORKER
chmod +x "$tmp/fake worker"
# A separate live editor must never even receive TERM (not merely survive it).
cat > "$tmp/unrelated editor" <<'UNRELATED'
#!/usr/bin/env bash
trap ': > "$WATCH_TMP/unrelated-signalled"' TERM HUP INT
while :; do sleep 1; done
UNRELATED
chmod +x "$tmp/unrelated editor"
"$tmp/unrelated editor" & unrelated=$!
printf '%s\n' "$unrelated" > "$tmp/unrelated.pid"
cat > "$UNITY_BIN" <<'EDITOR'
#!/usr/bin/env bash
set -u
n=1
[ ! -f "$WATCH_RUN/count" ] || n=$(( $(< "$WATCH_RUN/count") + 1 ))
printf '%s\n' "$n" > "$WATCH_RUN/count"
printf '%s\n' "$$" > "$WATCH_RUN/editor-$n.pid"
printf 'android=%s xdg=%s timeout=%s\n' "${ANDROID_USER_HOME-unset}" "${XDG_CONFIG_HOME-unset}" "${QR_UNITY_TIMEOUT-unset}" >> "$WATCH_RUN/env"
log=""; project=""; prev=""
for a in "$@"; do
  case "$prev" in -logFile) log="$a" ;; -projectPath) project="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$*" >> "$WATCH_RUN/args"
# The retry must start with no previous APK or log.
[ ! -e "$project/out.apk" ] || touch "$WATCH_RUN/stale-apk"
[ ! -e "$log" ] || touch "$WATCH_RUN/stale-log"
mode="$WATCH_MODE"
case "$mode:$n" in
  once:1|retry-fails:1|retry-missing:1|twice:*|silent:*|stubborn:1|descendants:1|late-descendants:1|grace:1) mode=stall ;;
  retry-fails:2|fail:*) mode=fail ;;
  retry-missing:2|missing:*) mode=missing ;;
esac
# Observe overlap at the retry boundary, not just after the whole build has finished.
if [ "$WATCH_MODE:$n" = descendants:2 ]; then
  for f in "$WATCH_RUN"/compiler-1.pid "$WATCH_RUN"/gradle-1.pid; do
    read -r pid < "$f"
    if ps -p "$pid" -o stat= 2>/dev/null | grep -q '^[[:space:]]*[^Z[:space:]]'; then
      printf '%s\n' "$pid" >> "$WATCH_RUN/overlapping-workers"
    fi
  done
fi
child=""
trap '[ -z "$child" ] || { kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; }; exit 143' TERM
[ "$WATCH_MODE" != late-descendants ] || trap 'exit 143' TERM
if [ "$mode" = stall ]; then
  [ "$WATCH_MODE" != silent ] || log=/dev/null
  printf 'stuck attempt %s\n' "$n" > "$log"
  if [ "$WATCH_MODE" = descendants ] || [ "$WATCH_MODE" = late-descendants ]; then
    "$WATCH_TMP/fake worker" compiler "$n" &
    # Deliberately not $child: these workers survive their editor's cooperative TERM handler.
    for i in {1..100}; do
      [ ! -s "$WATCH_RUN/gradle-$n.pid" ] || break
      sleep 0.01
    done
  fi
  if [ "$WATCH_MODE" = stubborn ] || [ "$WATCH_MODE" = grace ]; then
    # No child to orphan when the editor ignores TERM and needs KILL. The grace case's overall
    # timeout expires after stall detection but before the watchdog's two-second escalation.
    trap '' TERM
    [ "$WATCH_MODE" != grace ] || trap ': > "$WATCH_RUN/editor-term"' TERM
    deadline=$((SECONDS + 8))
    while [ "$SECONDS" -lt "$deadline" ]; do :; done
  else
    sleep 8 & child=$!; wait "$child"
  fi
  exit 23
fi
printf 'starting attempt %s\n' "$n" > "$log"
if [ "$mode" = healthy ]; then
  for i in 1 2 3 4; do sleep 1; printf 'progress %s\n' "$i" >> "$log"; done
fi
[ "$mode" != fail ] || exit 7
[ "$mode" != missing ] || exit 0
printf built > "$project/out.apk"
EDITOR
chmod +x "$UNITY_BIN"
# Exercise both wrapper implementations without depending on the host's gtimeout installation.
timeout_bin="$(command -v gtimeout || command -v timeout || true)"
if [ -n "$timeout_bin" ]; then ln -s "$timeout_bin" "$tmp/bin/gtimeout"; fi
original_path="$PATH"
run_case() {
  local backend="$1" mode="$2" limit="${3-2}" target="${4-build}"
  QR_RUN_DIR="$tmp/run-$backend-$mode"
  rm -rf "$QR_RUN_DIR"
  mkdir -p "$QR_RUN_DIR"
  export WATCH_RUN="$QR_RUN_DIR" WATCH_MODE="$mode"
  rc=0
  (
    QR_BUILD_STALL_SECONDS="$limit"
    # A function suffices for the GNU backend; hiding command -v forces the fallback on every host.
    if [ "$backend" = fallback ]; then
      command() { if [ "${1:-}" = -v ] && [ "${2:-}" = gtimeout ]; then return 1; fi; builtin command "$@"; }
    else PATH="$tmp/bin:$original_path"; fi
    if [ "$target" = attempt ]; then
      qr_build_attempt "$QR_RUN_DIR/build-unity.log" -batchmode -projectPath "$tmp/build" \
        -logFile "$QR_RUN_DIR/build-unity.log"
    else qr_build; fi
  ) > "$tmp/output" 2>&1 || rc=$?
}
all_workers_stopped() {
  local f pid
  for f in "$QR_RUN_DIR"/compiler-*.pid "$QR_RUN_DIR"/gradle-*.pid; do
    [ -f "$f" ] || continue
    read -r pid < "$f"
    # A terminated orphan can remain a zombie until the host reaps it; it cannot hold build resources.
    if ps -p "$pid" -o stat= 2>/dev/null | grep -q '^[[:space:]]*[^Z[:space:]]'; then return 1; fi
  done
}
stop_case_workers() {
  local f pid
  for f in "$QR_RUN_DIR"/compiler-*.pid "$QR_RUN_DIR"/gradle-*.pid; do
    [ -f "$f" ] || continue
    read -r pid < "$f"
    kill -KILL "$pid" 2>/dev/null || true
  done
}
all_editors_stopped() {
  local f pid
  for f in "$QR_RUN_DIR"/editor-*.pid; do
    [ -f "$f" ] || continue
    read -r pid < "$f"
    if kill -0 "$pid" 2>/dev/null; then return 1; fi
  done
}
for backend in fallback gtimeout; do
  if [ "$backend" = gtimeout ] && [ -z "$timeout_bin" ]; then
    echo 'skip gtimeout: no GNU timeout installed'; continue
  fi
  run_case "$backend" once
  check "$backend: a live silent editor is stopped and retried exactly once" \
    '[ "$rc" = 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 2 ] && grep -q "build: no progress for 2 s (last line: stuck attempt 1); retrying once" "$tmp/output" && all_editors_stopped'
  check "$backend: retry clears stale outputs and keeps the first stall log" \
    '[ ! -e "$QR_RUN_DIR/stale-apk" ] && [ ! -e "$QR_RUN_DIR/stale-log" ] && grep -q "stuck attempt 1" "$QR_RUN_DIR/build-stalled-unity.log" && [ ! -e "$QR_RUN_DIR/build-unity.log.stalled" ]'
  check "$backend: editor retains Android environment, args, overall timeout and build metadata" \
    '[ "$(grep -c "android=$tmp/android home xdg=unset timeout=30" "$QR_RUN_DIR/env")" = 2 ] && grep -q -- "-buildTarget Android -executeMethod Synthetic.Editor.Build.DevelopmentApk -quit -logFile" "$QR_RUN_DIR/args" && [ "$(qr_get build_commit)" = abc123456 ]'
  for mode in twice retry-fails retry-missing fail missing; do
    run_case "$backend" "$mode"
    expected=2; case "$mode" in fail|missing) expected=1 ;; esac
    check "$backend: $mode fails without extra retries" \
      '[ "$rc" != 0 ] && [ "$(< "$QR_RUN_DIR/count")" = "$expected" ] && grep -q "build failed" "$tmp/output" && all_editors_stopped'
  done
  run_case "$backend" healthy
  check "$backend: continued log growth allows a build longer than the stall limit" \
    '[ "$rc" = 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 1 ] && ! grep -q "retrying once" "$tmp/output" && all_editors_stopped'
  check "$backend: unrelated live process was not killed" 'kill -0 "$unrelated" 2>/dev/null'
  run_case "$backend" descendants
  check "$backend: compiler and Gradle descendants are drained before the retry starts" \
    '[ "$rc" = 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 2 ] && [ -s "$QR_RUN_DIR/compiler-1.pid" ] && [ -s "$QR_RUN_DIR/gradle-1.pid" ] && [ ! -e "$QR_RUN_DIR/overlapping-workers" ] && all_workers_stopped && all_editors_stopped'
  check "$backend: draining an attempt does not signal an unrelated editor" \
    'kill -0 "$unrelated" 2>/dev/null && [ ! -e "$tmp/unrelated-signalled" ]'
  stop_case_workers
  # Fractional overall deadline avoids racing the integer-second stall poll / two-second grace boundary.
  QR_BUILD_TIMEOUT=2.5
  run_case "$backend" grace 1 attempt
  check "$backend: overall timeout during stall grace preserves 124 and writes no stall marker" \
    '[ "$rc" = 124 ] && [ "$(< "$QR_RUN_DIR/count")" = 1 ] && [ -f "$QR_RUN_DIR/editor-term" ] && grep -q "timed out after 2.5s" "$tmp/output" && [ ! -e "$QR_RUN_DIR/build-unity.log.stalled" ] && all_editors_stopped'
  run_case "$backend" grace 1
  check "$backend: overall timeout during stall grace fails the build without retry" \
    '[ "$rc" != 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 1 ] && grep -q "Unity exit 124" "$tmp/output" && ! grep -q "retrying once" "$tmp/output" && [ ! -e "$QR_RUN_DIR/build-unity.log.stalled" ] && [ ! -e "$QR_RUN_DIR/build-stalled-unity.log" ] && all_editors_stopped'
  QR_BUILD_TIMEOUT=3.5
  run_case "$backend" late-descendants 1 attempt
  check "$backend: deadline crossed while draining a cooperative editor's workers preserves 124" \
    '[ "$rc" = 124 ] && [ "$(< "$QR_RUN_DIR/count")" = 1 ] && [ -s "$QR_RUN_DIR/gradle-1.pid" ] && grep -q "timed out after 3.5s" "$tmp/output" && [ ! -e "$QR_RUN_DIR/build-unity.log.stalled" ] && all_workers_stopped && all_editors_stopped'
  run_case "$backend" late-descendants 1
  check "$backend: late descendant cleanup fails the build without an extra attempt" \
    '[ "$rc" != 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 1 ] && [ -s "$QR_RUN_DIR/gradle-1.pid" ] && grep -q "Unity exit 124" "$tmp/output" && ! grep -q "retrying once" "$tmp/output" && [ ! -e "$QR_RUN_DIR/build-unity.log.stalled" ] && [ ! -e "$QR_RUN_DIR/build-stalled-unity.log" ] && all_workers_stopped && all_editors_stopped'
  QR_BUILD_TIMEOUT=30
  check "$backend: all per-attempt tracking directories are cleaned" \
    '[ -z "$(find "$tmp" -type d -name "build-watch.*" -print)" ]'
done
for mode in silent stubborn; do
  run_case fallback "$mode"
  expected=2
  if [ "$mode" = silent ]; then
    check 'a never-created log also stalls and fails after one retry' \
      '[ "$rc" != 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 2 ] && grep -q "last line: ); retrying once" "$tmp/output" && all_editors_stopped'
  else
    check 'TERM-ignoring editor is killed before starting the retry' \
      '[ "$rc" = 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 2 ] && all_editors_stopped'
  fi
done
# Total timeout must remain an ordinary failure, never a stall-triggered retry.
QR_BUILD_TIMEOUT=1
run_case fallback twice 20
check 'existing overall timeout still fails without retry' \
  '[ "$rc" != 0 ] && [ "$(< "$QR_RUN_DIR/count")" = 1 ] && grep -q "timed out after 1s" "$tmp/output" && ! grep -q "retrying once" "$tmp/output" && all_editors_stopped'
QR_BUILD_TIMEOUT=30
for limit in '' 0 -1 1.5 nope 08 999999999999999999999; do
  run_case fallback "invalid-${limit:-empty}" "$limit"
  check "invalid stall setting '$limit' is rejected before launching an editor" \
    '[ "$rc" != 0 ] && [ ! -f "$QR_RUN_DIR/count" ] && grep -q "QR_BUILD_STALL_SECONDS" "$tmp/output"'
done
# Inspect the default at the attempt boundary without waiting five minutes.
(
  unset QR_BUILD_STALL_SECONDS
  qr_build_attempt() { printf '%s\n' "$QR_BUILD_STALL_SECONDS" > "$tmp/default"; printf built > "$tmp/build/out.apk"; }
  qr_build
) > "$tmp/output" 2>&1
check 'stall limit defaults to 300 seconds' '[ "$(< "$tmp/default")" = 300 ]'
if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo 'all passed'
