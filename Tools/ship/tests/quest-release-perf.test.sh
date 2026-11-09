#!/usr/bin/env bash
# Scripted performance capture against synthetic adb only; no editor or headset.
# shellcheck disable=SC2016 # check evaluates assertions in the fixture's scope.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../quest-release.sh"
. "$here/lib/quest-release-config.sh"
. "$here/lib/quest-release-fixture.sh"
# This suite mutates config between cases; bypass immutable-config memoization.
# Still use the runner's real jq, without a Python launcher for each scalar read.
jq() { command "${SHIP_TEST_REAL_JQ:-jq}" "$@"; }
worker="${1:-}"
if [ "$worker" = --cancel-worker ]; then
  tmp="$QR_PERF_TEST_TMP"
else
  tmp="$(mktemp -d)"
fi
owner=''; watchdog=''
cleanup() {
  if [ -n "$owner" ]; then
    kill -TERM "$owner" 2>/dev/null || true
    wait "$owner" 2>/dev/null || true
  fi
  if [ -n "$watchdog" ]; then
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
[ "$worker" = --cancel-worker ] || trap cleanup EXIT
export QUEST_REPO="$tmp" QUEST_WT_ROOT="$tmp/wt" QUEST_LOG_ROOT="$tmp/logs"
export QUEST_BACKUP_ROOT="$tmp" QUEST_APK_DIR="$tmp/apks"
export QUEST_ADB_WAIT=1 QUEST_LAUNCH_WAIT=1 QUEST_WAIT_GRACE=0
# Unique IDs cannot collide with a real device's shared lock.
token="${tmp##*/}"; token="${token//./-}"
a="synthetic-perf-A_$token"; b="synthetic-perf-B_$token"
sha='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
fixture_id() {
  case "$1" in "$a") echo a ;; "$b") echo b ;; *) return 99 ;; esac
}
# Use real epoch-formatted timestamps, including adjacent seconds for streaks.
emit_samples() {
  local profile="$1" i app stale fields base
  base="$(command cat "$state/window-start" 2>/dev/null || command cat "$state/clock")"
  [ "$profile" != empty ] || return 0
  local count="${QR_PERF_SECONDS:-20}" pid=4242
  case "$profile" in
    truncated|early-exit) count=3 ;;
    slow-probes) count=$(( $(command cat "$state/clock") - base + 20 )) ;;
  esac
  [ "$profile" != foreign ] || pid=8888
  for ((i=1; i<=count; i++)); do
    app="$(((i - 1) % 20 + 1))"; [ "$app" != 20 ] || app=30
    stale=0
    case "$i" in 2|3|10) stale=1 ;; esac
    [ "$profile" != app-fail ] || app=30
    [ "$profile" != stale-fail ] || stale=2
    # Two hitches in the requested 20 seconds fail both gates, but dilution
    # with another 40+ healthy seconds would make both pass.
    if [ "$profile" = slow-probes ]; then
      app=5; stale=0
      if [ "$i" = 2 ] || [ "$i" = 3 ]; then app=30; stale=10; fi
    fi
    fields="FPS=72/72,Stale=$stale,App=${app}ms,CPU=6ms,GPU=4ms,CPU4/GPU=4/3,Temp=$((35 + i / 20))C"
    if [ "$i" = 4 ]; then
      fields="Temp=35C, GPU=4ms, App=${app}ms, Stale=$stale, CPU4/GPU=4/3, CPU=6ms, FPS=72/72"
    fi
    case "$profile:$i" in
      missing-app:10) fields="FPS=72,Stale=$stale,CPU=6ms,GPU=4ms" ;;
      missing-stale:10) fields="FPS=72,App=${app}ms,CPU=6ms,GPU=4ms" ;;
      missing-fps:10) fields="Stale=$stale,App=${app}ms,CPU=6ms,GPU=4ms" ;;
      optional:*) fields="FPS=72,Stale=$stale,App=${app}ms" ;;
    esac
    [ "$profile" != mixed ] || { [ "$i" -le 3 ] || pid=8888; }
    [ "$profile" != gapped ] || base="$((base + 2))"
    printf '%s.500 %s %s I VrApi: %s\n' "$((base + i - 1))" "$pid" "$pid" "$fields"
  done
  # Other tags never contribute, even when they contain familiar field names.
  printf '%s.000 4242 4242 I OtherTag: FPS=1,Stale=99,App=999ms\n' "$base"
  if [ "$profile" = diagnostic ]; then
    printf '%s.000 4242 4242 I VrApi: compositor initialized\n' "$base"
  fi
}
# Persist virtual elapsed time across adb command substitutions. Slow probes
# cost one second each without making this synthetic suite wait in real time.
qr_perf_now() { command cat "$tmp/state/$(fixture_id "$QUEST_SERIAL")/clock"; }
advance_clock() {
  local now
  now="$(command cat "$state/clock")"
  echo "$((now + $1))" > "$state/clock"
}
# Model the device's buffered logcat: warm-up fills it, -c empties it, and
# capture adds its own records. A missing/misordered clear contaminates stats.
qr_perf_sleep() {
  local id state phase profile child
  id="$(fixture_id "$QUEST_SERIAL")" || return 99
  state="$tmp/state/$id"
  phase="$(command cat "$state/phase")"
  advance_clock "$1"
  printf '%s|sleep %s %s\n' "$QUEST_SERIAL" "$1" "$phase" >> "$tmp/events"
  if [ "$phase" = warmup ]; then
    printf '%s.000 4242 4242 I VrApi: FPS=1,Stale=99,App=999ms\n' "$(date +%s)" >> "$state/buffer"
    echo capture > "$state/phase"
  else
    if [ "${QR_PERF_CANCEL:-0}" = 1 ]; then
      /bin/sleep 300 & child=$!
      printf '%s\n' "$child" > "$tmp/capture-child.pid"
      qr_fixture_ready "$tmp/capture.ready" "$child"
      wait "$child"
    else
      profile="$(command cat "$state/profile")"
      local elapsed=0
      [ ! -f "$state/elapsed" ] || elapsed="$(command cat "$state/elapsed")"
      elapsed=$((elapsed + $1))
      echo "$elapsed" > "$state/elapsed"
    fi
  fi
}
# Unknown adb invocations fail closed. There is no fallback to an installed adb.
adb() {
  local id state fault profile
  [ "${1:-}" = -s ] && [ "$#" -ge 3 ] || return 99
  id="$(fixture_id "$2")" || return 99
  state="$tmp/state/$id"; shift 2
  fault="$(command cat "$state/fault")"
  profile="$(command cat "$state/profile")"
  printf '%s|%s\n' "$id" "$*" >> "$tmp/adb.log"
  printf '%s|%s\n' "$id" "$*" >> "$tmp/events"
  case "$1" in
    get-state) [ "$fault" != device ] || return 1; echo device ;;
    wait-for-device) return 1 ;;
    logcat)
      case " $* " in
        *' -c '*)
          [ "$fault" != clear ] || return 1
          : > "$state/buffer"
          command cat "$state/clock" > "$state/window-start"
          echo cleared >> "$state/clears" ;;
        *' -d '*)
          [ "$fault" != logcat ] || return 1
          emit_samples "$profile" >> "$state/buffer"
          command cat "$state/buffer" ;;
        *) return 99 ;;
      esac ;;
    shell)
      shift
      case "$*" in
        'date +%s')
          [ "$fault" != clock ] || return 1
          if [ "$fault" = bad-clock ]; then echo invalid; return 0; fi
          command cat "$state/clock" | tee "$state/window-start" ;;
        'getprop ro.product.manufacturer') echo Oculus ;;
        'getprop ro.product.model') echo 'Synthetic Quest' ;;
        'pidof '*)
          [ "$profile" != slow-probes ] || advance_clock 1
          if [ -f "$state/elapsed" ]; then
            case "$profile" in
              early-exit) printf '\nqr_pid_rc=1\n'; return 0 ;;
              replaced) printf '8888\nqr_pid_rc=0\n'; return 0 ;;
            esac
          fi
          printf '4242\nqr_pid_rc=0\n' ;;
        'dumpsys activity activities')
          [ "$profile" != slow-probes ] || advance_clock 1
          if [ "$profile" = background ] && [ -f "$state/elapsed" ]; then
            echo 'mResumedActivity: ActivityRecord{abc u0 other.synthetic/.Main t1}'
          else
            printf 'mResumedActivity: ActivityRecord{abc u0 %s/.Main t1}\n' "$QR_PKG"
          fi ;;
        'dumpsys package '*)
          [ "$fault" != package ] || return 1
          [ "$profile" = optional ] || printf 'versionName=synthetic-build\nversionCode=42 minSdk=32\n' ;;
        'am broadcast -a com.oculus.vrpowermanager.prox_close')
          [ "$fault" != proximity ] || return 1 ;;
        'am broadcast -a com.oculus.vrpowermanager.automation_disable')
          echo attempted >> "$state/restore-attempts"
          [ "$fault" != restore ] || return 1
          [ ! -f "$QUEST_LOG_ROOT/last-result" ] || : > "$tmp/early-result"
          echo restored >> "$state/restored" ;;
        'am start '*)
          [ "$fault" != launch ] || return 1
          if [ "$fault" = launch-output ]; then echo 'Error: synthetic activity resolution failure'; fi ;;
        *) return 99 ;;
      esac ;;
    *) return 99 ;;
  esac
}
if [ "$worker" = --cancel-worker ]; then
  qr_main perf --seconds 20 --warmup 0
  exit $?
fi

fails=0
check() {
  if eval "$2"; then echo "ok   $1"
  else
    echo "FAIL $1 (rc=${rc:-?})"; fails=$((fails + 1))
    [ ! -f "$tmp/err" ] || tail -n 5 "$tmp/err"
    [ ! -f "${report:-}" ] || command cat "$report"
  fi
}
configure() {
  jq "$1" "$YETIKIT_CONFIG" > "$tmp/config.next" && mv "$tmp/config.next" "$YETIKIT_CONFIG"
}
reset_case() {
  rm -rf "$QUEST_LOG_ROOT" "$tmp/state"
  rm -f "$tmp/capture.ready" "$tmp/capture-child.pid" "$tmp/early-result"
  qr_test_config "$tmp/config"
  configure '.quest.launchArgs = ["-scene", "Synthetic Scene"] |
    .quest.perf = {seconds:20, warmupSeconds:3, maxStalePercent:1,
      maxP95AppMs:20, devices:{"Synthetic Quest":"gate"}}'
  local id
  for id in a b; do
    mkdir -p "$tmp/state/$id"
    echo healthy > "$tmp/state/$id/profile"
    echo none > "$tmp/state/$id/fault"
    echo warmup > "$tmp/state/$id/phase"
    echo 1700000000 > "$tmp/state/$id/clock"
    : > "$tmp/state/$id/buffer"
  done
  : > "$tmp/adb.log"; : > "$tmp/events"
}
load_report() {
  run_dir="$(
    [ -f "$QUEST_LOG_ROOT/current.env" ] || exit 0
    . "$QUEST_LOG_ROOT/current.env"
    printf '%s\n' "$QR_RUN_DIR"
  )"
  report="$run_dir/perf-summary.json"
}
run() {
  QUEST_SERIAL="$1"; export QUEST_SERIAL; shift
  rc=0
  ( qr_main "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
  load_report
}
json_is() { [ -s "$report" ] && jq -e "$1" "$report" >/dev/null; }
restored() { [ -s "$tmp/state/$1/restored" ]; }

reset_case
# Cache only immutable fixture scalars; all perf reads and schema validation stay
# real because this suite mutates those settings on each case.
. "$here/lib/quest-release-config-cache.sh"
qr_config || exit 1
qr_test_cache_config_reads || exit 1
qr_cached_get="$(declare -f qr_config_get)"
eval "${qr_cached_get/qr_config_get ()/qr_perf_fixture_get ()}"
qr_config_get() {
  case "$1" in
    .quest.perf*) printf '%s\n' "$QR_CONFIG_JSON" | command "${SHIP_TEST_REAL_JQ:-jq}" -r "$1" ;;
    *) qr_perf_fixture_get "$1" ;;
  esac
}
jq() { command "${SHIP_TEST_REAL_JQ:-jq}" "$@"; }
# Seed the real state path with synthetic APK provenance, without a build.
( qr_config && qr_load_state && qr_set apk_sha256 "$sha" )
run "$a" perf
check 'scripted perf uses configured window, launches with configured scene and restores proximity' \
  '[ "$rc" = 0 ] && json_is '\''.overall == "PASS" and .mode == "gate" and .seconds == 20 and .warmupSeconds == 3 and .scene == "Synthetic Scene"'\'' && grep -Fq "'\''Synthetic Scene'\''" "$tmp/adb.log" && restored a'
check 'healthy hand-computed stats use nearest-rank p95, not maximum or interpolated percentile' \
  'json_is '\''.samples == 20 and .averageFps == 72 and .p95AppMs == 19 and .worstAppMs == 30 and .longestStaleStreak == 2 and .cpuMs == 6 and .gpuMs == 4 and ((.stalePercent - (3 / 1440 * 100)) | fabs) < 0.000001 and .gates.app == {value:19,limit:20,verdict:"PASS"} and .gates.stale.verdict == "PASS"'\'''
check 'summary retains model, CPU4/GPU levels, thermal endpoints and APK build stamp' \
  'json_is '\''.model == "Synthetic Quest" and .levels == "4/3" and .thermalStart == "35C" and .thermalEnd == "36C" and .versionName == "synthetic-build" and (.versionCode | tostring) == "42"'\'' && jq -e --arg sha "$sha" '\''.apkSha256 == $sha'\'' "$report" >/dev/null'
check 'warm-up records are cleared after warm-up and before the capture window' \
  '[ "$(grep -E "sleep|logcat -c" "$tmp/events" | cut -d "|" -f2-)" = "$(printf "sleep 3 warmup\nlogcat -c\n"; printf "sleep 1 capture\n%.0s" {1..20})" ] && [ "$(wc -l < "$tmp/state/a/clears")" = 1 ] && ! grep -q "VrApi: FPS=1,Stale=99,App=999" "$run_dir/perf-logcat.txt" && [ -s "$run_dir/perf-summary.txt" ]'

wrc=0; ( qr_main wait 0 ) > "$tmp/wait.out" 2>&1 || wrc=$?
check 'wait succeeds for scripted perf and prints performance measurements' \
  '[ "$wrc" = 0 ] && grep -q "Quest performance: PASS" "$tmp/wait.out" && grep -q "App p95 (per-second samples)" "$tmp/wait.out"'

reset_case
run "$a" perf --seconds 7 --warmup 0
check 'CLI overrides configured seconds and accepts zero warm-up' \
  '[ "$rc" = 0 ] && json_is '\''.seconds == 7 and .warmupSeconds == 0'\'' && grep -q "sleep 0 warmup" "$tmp/events" && [ "$(grep -c "sleep 1 capture" "$tmp/events")" = 7 ]'

reset_case
configure 'del(.quest.perf.seconds, .quest.perf.warmupSeconds)'
run "$a" perf
check 'absent window settings use 60-second capture and 10-second warm-up defaults' \
  '[ "$rc" = 0 ] && json_is '\''.seconds == 60 and .warmupSeconds == 10'\'''

reset_case
echo slow-probes > "$tmp/state/a/profile"
run "$a" perf
check 'slow adb probes cannot extend the window and dilute failing hitches' \
  '[ "$rc" = 1 ] && json_is '\''.overall == "FAIL" and .samples == 20 and .p95AppMs == 30 and .gates.app.verdict == "FAIL" and .gates.stale.verdict == "FAIL"'\'' && restored a'
check 'elapsed deadline includes blocking probe time rather than adding it to every second' \
  '[ "$(grep -c "sleep 1 capture" "$tmp/events")" -le 7 ]'
# The dump deliberately includes healthy rows after the boundary. They are
# still present in the raw artifact, but must not enter any summary statistic.
check 'raw post-window records are excluded from the measurement' \
  '[ "$(grep -c "I VrApi:" "$run_dir/perf-logcat.txt")" -gt 20 ] && json_is '\''.averageFps == 72 and .worstAppMs == 30'\'''

for profile in app-fail stale-fail; do
  reset_case
  echo "$profile" > "$tmp/state/a/profile"
  run "$a" perf
  check "$profile fails its gate without average FPS hiding the failure" \
    '[ "$rc" = 1 ] && json_is '\''.overall == "FAIL" and .averageFps == 72 and ([.gates[].verdict] | index("FAIL") != null)'\'' && restored a'
done

reset_case
configure 'del(.quest.perf.maxStalePercent, .quest.perf.maxP95AppMs)'
run "$a" perf
check 'default gates enforce one percent stale and the 13.9ms frame budget' \
  '[ "$rc" = 1 ] && json_is '\''.gates.stale.limit == 1 and .gates.app.limit == 13.9 and .gates.app.verdict == "FAIL"'\'''

reset_case
configure '.quest.perf.maxP95AppMs = 19 | .quest.perf.maxStalePercent = (3 / 1440 * 100)'
run "$a" perf
check 'both gates accept values exactly at their configured limits' \
  '[ "$rc" = 0 ] && json_is '\''.overall == "PASS" and .gates.app.verdict == "PASS" and .gates.stale.verdict == "PASS"'\'''

for model_mode in report unknown; do
  reset_case
  if [ "$model_mode" = report ]; then
    configure '.quest.perf.devices["Synthetic Quest"] = "report"'
  else
    configure 'del(.quest.perf.devices)'
  fi
  echo app-fail > "$tmp/state/a/profile"
  run "$a" perf
  check "$model_mode device is report-only, retaining failed gate verdict rather than claiming PASS" \
    '[ "$rc" = 0 ] && json_is '\''.overall == "REPORT" and .mode == "report" and .gates.app.verdict == "FAIL"'\'' && restored a'
done

reset_case
configure '.quest.perf.devices["Synthetic Quest"] = "report"'
echo stale-fail > "$tmp/state/a/profile"
run "$a" perf
check 'stale above one percent reports exit zero on report-only device' \
  '[ "$rc" = 0 ] && json_is '\''.overall == "REPORT" and .stalePercent > 1 and .gates.stale.verdict == "FAIL"'\'' && restored a'

for profile in early-exit truncated gapped foreign mixed replaced background; do
  reset_case
  echo "$profile" > "$tmp/state/a/profile"
  run "$a" perf
  check "$profile cannot certify an incomplete or different workload" \
    '[ "$rc" = 3 ] && json_is '\''.overall == "INFRA" and (.message | length) > 0'\'' && restored a'
  wrc=0; ( qr_main wait 0 ) > "$tmp/wait.out" 2>&1 || wrc=$?
  check "wait propagates $profile capture failure" '[ "$wrc" = 1 ]'
done

reset_case
configure '.quest.perf.devices["Synthetic Quest"] = "report"'
echo truncated > "$tmp/state/a/profile"
run "$a" perf
check 'incomplete report-only capture is also INFRA, not REPORT' \
  '[ "$rc" = 3 ] && json_is '\''.overall == "INFRA"'\'' && restored a'

reset_case
echo restore > "$tmp/state/a/fault"
run "$a" perf
check 'failed proximity restoration is INFRA and EXIT retries restoration' \
  '[ "$rc" = 3 ] && json_is '\''.overall == "INFRA" and (.message | contains("restoration failed"))'\'' && [ "$(wc -l < "$tmp/state/a/restore-attempts")" -ge 2 ]'

for field in app stale fps; do
  reset_case
  echo "missing-$field" > "$tmp/state/a/profile"
  run "$a" perf
  if [ "$field" = app ]; then gate=app; else gate=stale; fi
  check "one sample missing $field makes the affected gate unavailable, never PASS" \
    '[ "$rc" != 0 ] && json_is '\''.samples == 20 and .overall != "PASS"'\'' && jq -e --arg gate "$gate" '\''.gates[$gate].value == "unavailable" and .gates[$gate].verdict == "FAIL"'\'' "$report" >/dev/null && restored a'
done

reset_case
configure '.quest.perf.devices["Synthetic Quest"] = "report"'
echo missing-app > "$tmp/state/a/profile"
run "$a" perf
check 'report-only missing input stays unavailable rather than claiming a passing gate' \
  '[ "$rc" = 0 ] && json_is '\''.overall == "REPORT" and .gates.app.value == "unavailable" and .gates.app.verdict == "unavailable"'\'''

reset_case
echo optional > "$tmp/state/a/profile"
run "$a" perf
check 'missing optional metadata/timings are explicit unavailable strings without blocking measurable gates' \
  '[ "$rc" = 0 ] && json_is '\''.overall == "PASS" and .cpuMs == "unavailable" and .gpuMs == "unavailable" and .levels == "unavailable" and .thermalStart == "unavailable" and .thermalEnd == "unavailable" and .versionName == "unavailable" and .versionCode == "unavailable" and .apkSha256 == "unavailable"'\'''

reset_case
echo diagnostic > "$tmp/state/a/profile"
run "$a" perf
check 'unrelated VrApi diagnostic lines are not timing samples' \
  '[ "$rc" = 0 ] && json_is '\''.overall == "PASS" and .samples == 20 and .p95AppMs == 19'\'''

reset_case
echo empty > "$tmp/state/a/profile"
run "$a" perf
check 'empty log capture is INFRA with unavailable gate values and an explanation' \
  '[ "$rc" = 3 ] && json_is '\''.overall == "INFRA" and .samples == 0 and .p95AppMs == "unavailable" and .stalePercent == "unavailable" and (.message | length) > 0'\'' && restored a'

for fault in clear logcat clock bad-clock launch launch-output proximity package; do
  reset_case
  echo "$fault" > "$tmp/state/a/fault"
  run "$a" perf
  check "adb $fault failure is INFRA and restores proximity" \
    '[ "$rc" = 3 ] && json_is '\''.overall == "INFRA" and (.message | length) > 0'\'' && restored a'
done

for options in '--seconds 0' '--seconds -1' '--seconds 1.5' '--seconds' '--warmup -1' '--warmup 0.5' '--unknown'; do
  reset_case
  # Intentional splitting: each fixture string contains CLI tokens only.
  # shellcheck disable=SC2086
  run "$a" perf $options
  check "invalid CLI $options refuses before any adb mutation" \
    '[ "$rc" != 0 ] && ! grep -Eq "am start|am broadcast|logcat -c" "$tmp/adb.log"'
done
for mutation in '.quest.perf.seconds = 0' '.quest.perf.warmupSeconds = -1' '.quest.perf.maxStalePercent = -1' '.quest.perf.maxP95AppMs = "bad"' '.quest.perf.devices["Synthetic Quest"] = "bad"'; do
  reset_case
  configure "$mutation"
  run "$a" perf
  check "invalid config $mutation refuses without adb work" '[ "$rc" != 0 ] && [ ! -s "$tmp/adb.log" ]'
done

for outcomes in healthy-healthy healthy-infra infra-healthy fail-infra infra-fail; do
  reset_case
  case "$outcomes" in
    healthy-healthy) expected=0 ;;
    healthy-infra) expected=3; echo logcat > "$tmp/state/b/fault" ;;
    infra-healthy) expected=3; echo logcat > "$tmp/state/a/fault" ;;
    fail-infra) expected=1; echo app-fail > "$tmp/state/a/profile"; echo logcat > "$tmp/state/b/fault" ;;
    infra-fail) expected=1; echo logcat > "$tmp/state/a/fault"; echo app-fail > "$tmp/state/b/profile" ;;
  esac
  run "$a,$b" perf
  check "multi-serial $outcomes continues in order with worst precedence 1 > 3 > 0" \
    '[ "$rc" = "$expected" ] && restored a && restored b && [ "$(grep "|shell am start " "$tmp/adb.log" | cut -d "|" -f1)" = "$(printf "a\nb")" ] && [ -s "$run_dir/devices/$a/perf-summary.json" ] && [ -s "$run_dir/devices/$b/perf-summary.json" ] && [ ! -e "$run_dir/perf-summary.json" ] && grep -Fq "perf[$a]:" "$run_dir/summary.txt" && grep -Fq "perf[$b]:" "$run_dir/summary.txt"'
done

wrc=0; ( qr_main wait 0 ) > "$tmp/wait.out" 2>&1 || wrc=$?
check 'wait fails mixed perf and preserves both per-device summaries' \
  '[ "$wrc" = 1 ] && grep -Fq "perf[$a]:" "$tmp/wait.out" && grep -Fq "perf[$b]:" "$tmp/wait.out"'

# Real qr_main owner/traps, real run lock and real cancel/drain; only adb and
# capture sleeping are fake. Readiness is published inside the capture window.
reset_case
export QR_PERF_TEST_TMP="$tmp" QR_PERF_CANCEL=1 QUEST_SERIAL="$a"
if declare -F qr_perf >/dev/null; then
  set -m
  qr_fixture_bash "$here/quest-release-perf.test.sh" --cancel-worker > "$tmp/cancel.out" 2>&1 & owner=$!
  set +m
  ready=1
  qr_fixture_wait_ready "$tmp/capture.ready" "$owner" || ready=0
  recorded="$(command cat "$QUEST_LOG_ROOT/run.lock/pid" 2>/dev/null)"
  before="$(wc -l < "$tmp/adb.log")"
  run "$a" perf --seconds 1 --warmup 0
  check 'active capture holds the real run lock and rejects a competing perf command' \
    '[ "$ready" = 1 ] && [ "$recorded" = "$owner" ] && [ "$rc" = 1 ] && [ "$(wc -l < "$tmp/adb.log")" = "$before" ] && grep -q "another quest-release run is active" "$tmp/err"'
  qr_fixture_watchdog "$owner" & watchdog=$!
  kill -TERM "$owner" 2>/dev/null || true
  rc=0; wait "$owner" || rc=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  watchdog=''; owner=''
  load_report
  stopped=1
  if [ -f "$tmp/capture-child.pid" ]; then
    child="$(command cat "$tmp/capture-child.pid")"
    if ps -p "$child" -o stat= | grep -qv '^[[:space:]]*Z'; then
      stopped=0; kill -KILL "$child" 2>/dev/null || true
    fi
  else
    stopped=0
  fi
  check 'TERM drains capture and logs proximity restoration before publishing cancellation and releasing lock' \
    '[ "$ready" = 1 ] && [ "$rc" = 1 ] && [ "$stopped" = 1 ] && restored a && [ ! -e "$QUEST_LOG_ROOT/run.lock" ] && [ ! -f "$tmp/early-result" ] && grep -q "^cmd=perf$" "$QUEST_LOG_ROOT/last-result" && grep -q "^rc=1$" "$QUEST_LOG_ROOT/last-result" && json_is '\''.overall != "PASS"'\'''
else
  check 'perf must be sourced before real TERM/run-lock regression can run' false
fi
unset QR_PERF_CANCEL
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo 'all passed'
