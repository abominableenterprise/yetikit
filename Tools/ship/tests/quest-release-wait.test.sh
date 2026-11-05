#!/usr/bin/env bash
# shellcheck disable=SC2016 # check takes single-quoted conditions, expanded by eval
# shellcheck disable=SC2034 # rc is read inside those conditions
# shellcheck disable=SC2317 # on_sleep hooks run from the fake sleep
# Tests `quest-release.sh wait [minutes]` (Tools/ship/README.md): it blocks until the current run's lock is gone (or
# its PID dead) and the run folder has a fresh summary.txt, prints it and exits 0 / 1 by the install (or a gate-only
# run's gate), exits 124 on timeout with the logs' last lines, prints at most one progress line a minute, and changes
# nothing. `sleep` and the clock are stubbed (FAKE_NOW, advanced by the fake sleep); never runs Unity or adb.
# bash 3.2 compatible. Run: Tools/ship/test-all.sh
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/quest-release.sh"
. "$(dirname "$script")/tests/lib/quest-release-fixture.sh"
# A nohup-launched suite also ignores HUP. Bash cannot install a handler for
# signals ignored at entry: reset all tested dispositions BEFORE the fresh Bash.
qr_fixture_bash() {
  exec perl -e '$SIG{HUP} = "DEFAULT"; $SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV; die "exec: $!"' bash "$@"
}
SIGNAL_COMPLETION_TIMEOUT_SECONDS=30
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; kill "${live:-}" 2>/dev/null' EXIT
. "$(dirname "$0")/lib/quest-release-config.sh"
qr_test_config "$tmp/config"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ -z "${QR_TEST_DEBUG:-}" ] || cat "$tmp/out" "$tmp/err"; fails=$((fails + 1)); fi; }

logs="$tmp/release-logs"
export QUEST_LOG_ROOT="$logs" QUEST_WT_ROOT="$tmp/wt" HOME="$tmp/home"
# shellcheck source=Tools/ship/quest-release.sh
. "$script"

# The fake clock: qr_wait_now prints FAKE_NOW; sleep advances it and runs the scenario's hook (the run moving on).
FAKE_NOW=1000000
qr_wait_now() { echo "$FAKE_NOW"; }
on_sleep() { :; }
sleep() { echo "$1" >> "$tmp/sleeps"; FAKE_NOW=$((FAKE_NOW + $1)); on_sleep; }

command sleep 600 >/dev/null 2>&1 & live=$! # a live PID for the lock (kill -0)

new_run() { # $1 install line ("" for none), $2 gate_result
  rm -rf "$logs"; mkdir -p "$logs/abc-1/summary"; run="$logs/abc-1"
  printf 'QR_SHA=abc\nQR_REF=origin/main\nQR_SHORT=abc\nQR_RUN_DIR=%s\n' "$run" > "$logs/current.env"
  echo "abc (origin/main)" > "$run/summary/commit"
  [ -z "$1" ] || echo "$1" > "$run/summary/install"
  [ -z "${2:-}" ] || echo "$2" > "$run/summary/gate_result"
}
lock() { mkdir -p "$logs/run.lock"; echo "$1" > "$logs/run.lock/pid"; echo "$run" > "$logs/run.lock/run_dir"; }
# The invocation's terminal result (lock.sh's qr_lock_result): $1 pid, $2 exit status, $3 command.
result() { printf 'pid=%s\ncmd=%s\nrc=%s\nrun=%s\n' "$1" "${3:-all}" "$2" "$run" > "$logs/last-result"; }
finish() { printf '==== Quest release summary ====\ninstall:     %s\n' "$(cat "$run/summary/install" 2>/dev/null)" > "$run/summary.txt"; }
# Every path under the logs with its size and mtime (perl: portable, sub-second).
tree() { find "$logs" | sort | perl -MTime::HiRes=stat -ne 'chomp; my @s = stat $_; print "$_ $s[7] $s[9]\n"'; }
run_wait() {
  rc=0; rm -f "$tmp/sleeps"; tree > "$tmp/tree-before"
  ( qr_main wait "$@" ) > "$tmp/out" 2> "$tmp/err" || rc=$?
}
unchanged() { tree | cmp -s - "$tmp/tree-before"; }
progress() { grep -c "^\[quest-release\] wait: [0-9]* min: phase" "$tmp/err"; }

# --- a run that finishes while we wait: the lock is released after a fresh summary.txt ----------------------------------------
new_run "not run yet"; lock "$live"
n=0; on_sleep() { n=$((n + 1)); if [ "$n" = 30 ]; then echo "install ok (/x.apk)" > "$run/summary/install"; finish; result "$live" 0; rm -rf "$logs/run.lock"; fi; }
run_wait 10
check "wait blocks while the lock is live, then prints summary.txt and exits 0 for install ok" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/sleeps")" = 30 ] && grep -q "^install:     install ok" "$tmp/out"'
check "while waiting it prints one progress line a minute with the phase, never more" \
  '[ "$(progress)" = 2 ] && grep -q "wait: 1 min: phase gate/build (gate running, build running)" "$tmp/err"'
on_sleep() { :; }

# --- already finished: no lock, a summary newer than the run's start ----------------------------------------------------------
new_run "skipped: gate failed (APK kept: /x.apk)"; finish; result 4242 1
run_wait
check "a finished run whose install was skipped: prints the summary and exits 1, takes no lock and changes nothing" \
  '[ "$rc" = 1 ] && grep -q "skipped: gate failed" "$tmp/out" && [ ! -e "$logs/run.lock" ] && unchanged'
new_run "install ok (/x.apk)"; echo "CRASH: fps none" > "$run/summary/launch"; finish; result 4242 0
run_wait
check "install ok but the launch crashed: exit 1 (even with exit status 0)" '[ "$rc" = 1 ]'
new_run "" passed; finish; result 4242 0 gate
run_wait
check "a gate-only run whose gate passed: exit 0" '[ "$rc" = 0 ] && grep -q "Quest release summary" "$tmp/out"'
new_run "" failed; finish; result 4242 1 gate
run_wait
check "a gate-only run whose gate failed: exit 1" '[ "$rc" = 1 ]'

# --- a command's verdict ignores stale outcomes from other commands ---------------------------------------------------------
for cmd in gate build verify prepare cleanup launch; do
  new_run "skipped: old install failure" passed; finish; result 4242 0 "$cmd"
  run_wait 2
  check "$cmd ignores a stale failed install" '[ "$rc" = 0 ]'
done
new_run "install ok (/x.apk)" failed; finish; result 4242 0 gate
run_wait 2
check "gate does not accept a stale successful install instead of its failed gate" '[ "$rc" = 1 ]'
for cmd in install rollback; do
  new_run "$cmd ok (/x.apk)" failed; echo 'CRASH: earlier launch' > "$run/summary/launch"
  finish; result 4242 0 "$cmd"; run_wait 2
  check "$cmd accepts its real success summary despite a stale launch crash and gate failure" '[ "$rc" = 0 ]'
  echo "$cmd ok (/x.apk), playtest.json CHANGED" > "$run/summary/install"; finish
  run_wait 2
  check "$cmd still rejects changed install data" '[ "$rc" = 1 ]'
  if [ "$cmd" = rollback ]; then other=install; else other=rollback; fi
  echo "$other ok (/x.apk)" > "$run/summary/install"; finish
  run_wait 2
  check "$cmd rejects a stale $other success summary" '[ "$rc" = 1 ]'
done

# --- a dead PID counts as finished; a summary older than the run's start does not --------------------------------------------
new_run "install ok (/x.apk)"; finish; result 4242 0; command sleep 1; lock 999999
run_wait 2
check "a lock whose PID is dead and an older run's result and summary: not finished, exit 1 with the logs" \
  '[ "$rc" = 1 ] && out=$(cat "$tmp/err") && case "$out" in *"without writing its result"*) true ;; *) false ;; esac && unchanged'
finish; result 999999 0
run_wait 2
check "a lock whose PID is dead and a fresh summary.txt: finished (exit 0); the stale lock is left alone" \
  '[ "$rc" = 0 ] && [ -d "$logs/run.lock" ] && [ ! -s "$tmp/sleeps" ]'

# --- the watched invocation's own exit status decides, never an earlier run's summary.
new_run "install ok (/x.apk)"; finish; result 4242 0 # a successful release
fake_jdk() { mkdir -p "$1/bin" && printf '#!/bin/sh\n' > "$1/bin/java" && chmod +x "$1/bin/java"; }
fake_jdk "$tmp/jdk"
( export JAVA_HOME="$tmp/jdk"; qr_main all --notes "$tmp/no-such-notes" ) > /dev/null 2>&1
run_wait 2
check "after a successful release, an \`all --notes <missing>\` that fails before prepare: exit 1, not the old install ok" \
  '[ "$rc" = 1 ] && grep -q "exited 1" "$tmp/err" && [ ! -e "$logs/run.lock" ]'
new_run "install ok (/x.apk)"; finish; result 4242 0
( unset JAVA_HOME; UNITY_HUB_EDITORS="$tmp/no-hub"; qr_main all ) > /dev/null 2>&1
run_wait 2
check "after a successful release, an \`all\` that stops at the Java setup: exit 1" '[ "$rc" = 1 ] && grep -q "exited 1" "$tmp/err"'
new_run "install ok (/x.apk)"; finish; result 4242 0; lock "$live"
n=0; on_sleep() { n=$((n + 1)); if [ "$n" = 3 ]; then finish; result "$live" 1 launch; rm -rf "$logs/run.lock"; fi; }
run_wait 2
check "a watched launch that fails after an earlier install ok: exit 1 by its exit status" '[ "$rc" = 1 ] && grep -q "launch, pid $live) exited 1" "$tmp/err"'
new_run "install ok (/x.apk)"; finish; result 4242 0; lock "$live"
n=0; on_sleep() { n=$((n + 1)); if [ "$n" = 3 ]; then finish; rm -rf "$logs/run.lock"; fi; }
run_wait 2
check "a watched run that ends without its own result (killed): exit 1, an older run's result does not count" \
  '[ "$rc" = 1 ] && grep -q "without writing its result" "$tmp/err"'
on_sleep() { :; }

# --- pin the first invocation even when another takes its lock between polls ------------------------------------------------
for has_result in yes no; do
  new_run "install ok (/x.apk)"; lock "$live"
  n=0; on_sleep() {
    n=$((n + 1))
    if [ "$n" = 1 ]; then
      finish
      [ "$has_result" = no ] || result "$live" 0
      echo "$$" > "$logs/run.lock/pid"
    fi
  }
  run_wait 2
  if [ "$has_result" = yes ]; then
    check "a replacement lock owner does not delay the watched PID's successful result" \
      '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/sleeps")" = 1 ] && grep -q "pid $live) exited 0" "$tmp/err"'
  else
    check "a replacement lock owner cannot hide the watched PID's missing result" \
      '[ "$rc" = 1 ] && [ "$(wc -l < "$tmp/sleeps")" = 1 ] && grep -q "pid $live.*without writing its result" "$tmp/err"'
  fi
done
new_run "install ok (/x.apk)"; lock "$live"
n=0; on_sleep() {
  n=$((n + 1))
  if [ "$n" = 1 ]; then
    finish; result "$$" 0
    echo "$$" > "$logs/run.lock/pid"
    mkdir -p "$logs/later-run"; echo "$logs/later-run" > "$logs/run.lock/run_dir"
  fi
}
run_wait 2
check "a replacement owner's successful result never substitutes for the watched PID's missing result" \
  '[ "$rc" = 1 ] && grep -q "pid $live.*without writing its result" "$tmp/err"'
on_sleep() { :; }

# --- prepare can publish its folder and hand the lock to gate entirely between polls.
# Hooks publish in a subshell: assigning the fixture's run must not overwrite qr_wait's dynamically scoped local run.
for previous in absent present; do
  for successor in gate later none; do
    new_run "install ok (/old.apk)"; finish; result 4242 0
    [ "$previous" = present ] || rm -f "$logs/current.env"
    lock "$live"; echo pending > "$logs/run.lock/run_dir"
    n=0; on_sleep() {
      n=$((n + 1))
      if [ "$n" = 1 ]; then (
        run="$logs/prepared-run"; mkdir -p "$run/summary"
        printf 'QR_RUN_DIR=%s\n' "$run" > "$logs/current.env"
        finish; echo 'prepared invocation summary' >> "$run/summary.txt"; result "$live" 0 prepare
        case "$successor" in
          none) rm -rf "$logs/run.lock" ;;
          gate) echo "$$" > "$logs/run.lock/pid"; echo "$run" > "$logs/run.lock/run_dir" ;;
          later)
            mkdir -p "$logs/successor-run"
            echo "$$" > "$logs/run.lock/pid"; echo "$logs/successor-run" > "$logs/run.lock/run_dir"
            printf 'QR_RUN_DIR=%s\n' "$logs/successor-run" > "$logs/current.env" ;;
        esac
        tree > "$tmp/tree-completed"
      ); fi
    }
    run_wait 2
    check "pending prepare with $previous prior state resolves its own result before $successor successor" \
      '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/sleeps")" = 1 ] && grep -q "^prepared invocation summary$" "$tmp/out" && ! grep -q "old.apk" "$tmp/out" && grep -q "prepare, pid $live) exited 0" "$tmp/err" && tree | cmp -s - "$tmp/tree-completed"'
  done
done

# An unresolved folder is not permission to accept another PID or a reused PID's stale result.
for invalid in pid stale; do
  new_run "install ok (/old.apk)"; lock "$live"; echo pending > "$logs/run.lock/run_dir"
  n=0; on_sleep() {
    n=$((n + 1))
    if [ "$n" = 1 ]; then (
      run="$logs/prepared-run"; mkdir -p "$run/summary"; finish
      if [ "$invalid" = pid ]; then result "$$" 0 prepare
      else result "$live" 0 prepare; perl -e 'utime 1, 1, $ARGV[0]' "$logs/last-result"; fi
      echo "$$" > "$logs/run.lock/pid"; echo "$run" > "$logs/run.lock/run_dir"
    ); fi
  }
  run_wait 2
  check "pending prepare rejects a result with invalid $invalid identity" \
    '[ "$rc" = 1 ] && grep -q "pid $live.*without writing its result" "$tmp/err" && [ ! -s "$tmp/out" ]'
done

# Once prepare's concrete folder is observed, neither its result nor a missing lock may redirect it.
for ending in replaced gone; do
  new_run "install ok (/x.apk)"; lock "$live"; echo pending > "$logs/run.lock/run_dir"
  n=0; on_sleep() {
    n=$((n + 1))
    ( case "$n" in
      1) echo "$logs/abc-1" > "$logs/run.lock/run_dir" ;;
      2)
        run="$logs/different-run"; mkdir -p "$run/summary"; finish; result "$live" 0 prepare
        printf 'QR_RUN_DIR=%s\n' "$run" > "$logs/current.env"
        if [ "$ending" = gone ]; then rm -rf "$logs/run.lock"
        else echo "$$" > "$logs/run.lock/pid"; echo "$run" > "$logs/run.lock/run_dir"; fi ;;
    esac )
  }
  run_wait 2
  check "prepare retains its observed concrete folder when the lock is $ending" \
    '[ "$rc" = 1 ] && [ "$(wc -l < "$tmp/sleeps")" = 2 ] && grep -q "without writing its result" "$tmp/err" && [ ! -s "$tmp/out" ]'
done
on_sleep() { :; }

# --- timestamp and run identity matter even if the first poll never saw a lock ---------------------------------------------
new_run "install ok (/x.apk)"; finish; result 4242 0
perl -e 'utime 1, 1, $ARGV[0]' "$logs/last-result"
run_wait 2
check "an older result without an observed lock cannot certify the current run" '[ "$rc" = 1 ]'
new_run "install ok (/x.apk)"; finish; result "$live" 0; lock "$live"
perl -e 'utime 1, 1, $ARGV[0]' "$logs/last-result"
n=0; on_sleep() { n=$((n + 1)); [ "$n" != 1 ] || rm -rf "$logs/run.lock"; }
run_wait 2
check "a result with a reused PID but predating the watched lock is rejected" '[ "$rc" = 1 ]'
on_sleep() { :; }
new_run "install ok (/x.apk)"; finish; result 4242 0
printf 'run=%s\n' "$logs/different-run" >> "$logs/last-result"
run_wait 2
check "a successful result for a different run folder cannot certify this summary" '[ "$rc" = 1 ]'

# Signals before prepare must replace the old result, even when wait never saw the short-lived lock.
for sig in HUP INT TERM; do
  new_run "install ok (/x.apk)"; finish; result 4242 0
  signal_script="$tmp/signal-$sig.sh"
  printf '. %q\nqr_java_setup() { kill -%s "$$"; }\nqr_main all\n' "$script" "$sig" > "$signal_script"
  # The hook is the readiness boundary: signal only after qr_main installed its
  # traps and acquired the lock, not after a guessed startup delay.
  started=$SECONDS
  ( qr_fixture_bash "$signal_script" ) > "$tmp/signal-out" 2>&1 & signal_owner=$!
  (
    trap 'kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null; exit' TERM
    command sleep "$SIGNAL_COMPLETION_TIMEOUT_SECONDS" & timer=$!
    wait "$timer"
    echo "$sig before prepare exceeded ${SIGNAL_COMPLETION_TIMEOUT_SECONDS}s" >&2
    cat "$tmp/signal-out" >&2
    kill -KILL "$signal_owner" 2>/dev/null
  ) & signal_watchdog=$!
  signal_rc=0; wait "$signal_owner" || signal_rc=$?
  kill "$signal_watchdog" 2>/dev/null; wait "$signal_watchdog" 2>/dev/null || true
  echo "info $sig before prepare: ${signal_rc} after $((SECONDS - started))s (bound ${SIGNAL_COMPLETION_TIMEOUT_SECONDS}s)"
  run_wait 2
  check "$sig before prepare writes its own failed result rather than accepting an old success" \
    '[ "$signal_rc" = 1 ] && [ "$rc" = 1 ] && grep -q "exited 1" "$tmp/err" && ! grep -q "^pid=4242$" "$logs/last-result" && [ ! -e "$logs/run.lock" ]'
done

# --- a live lock past the timeout: 124 with the last 5 lines of gate.out / build.out ------------------------------------------
new_run "not run yet"; lock "$live"; seq 1 20 | sed 's/^/gate line /' > "$run/gate.out"; seq 1 20 | sed 's/^/build line /' > "$run/build.out"
echo "Gfx;MacOnly: 3 tests" > "$run/summary/gate"
run_wait 3
check "a live lock held past a 3-minute wait exits 124" '[ "$rc" = 124 ] && grep -q "timed out after 3 min" "$tmp/err"'
check "on timeout it prints the last 5 lines of gate.out and build.out only" \
  'grep -q "^gate line 16$" "$tmp/out" && grep -q "^gate line 20$" "$tmp/out" && ! grep -q "^gate line 15$" "$tmp/out" && grep -q "^build line 20$" "$tmp/out" && ! grep -q "^build line 15$" "$tmp/out"'
check "it polled many times but printed at most one line a minute" \
  '[ "$(wc -l < "$tmp/sleeps")" -ge 30 ] && [ "$(progress)" -le 3 ] && [ "$(progress)" -ge 2 ] && grep -q "phase gate/build (gate done, build running)" "$tmp/err" && unchanged'
rm -f "$run/gate.out" "$run/build.out"; echo "12:00:00 install: adb install -r" > "$run/release.log"
echo "install stopped before adb install (see release.log)" > "$run/summary/install"
run_wait 1
check "with no gate.out / build.out, the timeout shows the run folder's logs and the install phase" \
  '[ "$rc" = 124 ] && grep -q "adb install -r" "$tmp/out" && grep -q "phase install" "$tmp/err"'
run_wait abc
check "wait rejects a non-numeric minutes argument" '[ "$rc" = 2 ]'
for minutes in 08 09; do
  # Numeric parsing does not depend on poll density; keep the fake-clock test
  # to one poll per minute instead of forking hundreds of timestamp readers.
  QUEST_WAIT_POLL=60 run_wait "$minutes"
  check "wait $minutes uses decimal minutes without an octal arithmetic error" \
    '[ "$rc" = 124 ] && grep -q "timed out after $((10#$minutes)) min" "$tmp/err" && ! grep -q "value too great for base" "$tmp/err"'
done

# --- the default is 45 minutes; no run at all fails after a short grace -------------------------------------------------------
new_run "not run yet"; lock "$live"
# Still omit the minutes argument and advance to the actual default deadline.
# The 3-minute case above separately asserts dense polling/progress throttling.
QUEST_WAIT_POLL=60 run_wait
check "wait with no argument waits 45 minutes" '[ "$rc" = 124 ] && grep -q "timed out after 45 min" "$tmp/err" && [ "$(progress)" -le 45 ]'
rm -rf "$logs"; mkdir -p "$logs"
run_wait 5
check "no run in the logs: exit 1 after the start grace, not the whole wait" \
  '[ "$rc" = 1 ] && grep -q "no quest-release run" "$tmp/err" && [ "$(wc -l < "$tmp/sleeps")" -le 4 ]'

check "wait never searches processes by command line" '! grep -nE "p(grep|kill)" "$(dirname "$script")/quest-release/wait.sh"'

if [ "$fails" != 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
