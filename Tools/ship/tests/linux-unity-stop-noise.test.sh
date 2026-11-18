#!/usr/bin/env bash
# test-all: serial
# Exercise real stop and Git lock retries with fake Unity, licensing and seat services.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-seat-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-seat-fixture.sh"

# Unlike the seat polling tests, stop's grace period and the Git retry must use real time.
rm "$tmp/bin/sleep"
ship_fixture_process_view "$tmp/process-view"
export PATH="$tmp/process-view:$PATH" SHIP_FIXTURE_PIDS='' UNITY_IDLE_RETURN_MINUTES=0

settings=ProjectSettings/TimeManager.asset
mkdir -p "$proj/ProjectSettings"
printf 'TimeManager:\n  Fixed Timestep: 0.013888889\n' > "$proj/$settings"
commit timestep
lock="$proj/.git/index.lock"
mutate='printf "TimeManager:\n  Fixed Timestep: 0.013888900\n" > ProjectSettings/TimeManager.asset
  touch "$FAKE_TMP/noise-ready"; exec /bin/sleep 90'
for command in scene lab; do
  reset 200
  printf '%s\n' "$good_ulf" > "$ULF"
  printf '5455 1\n' > "$state"
  rm -f "$tmp/noise-ready"
  env "${hub[@]}" UNITY_USERNAME=u UNITY_PASSWORD=p SHIP_READINESS_RUN="$tmp" UNITY_RETURN_ON_EXIT=1 \
    NOISE_GIT_TRIES=2 NOISE_GIT_DELAY=10 FAKE_MUTATE="$mutate" bash "$script" "$command" > "$tmp/run.log" 2>&1 &
  readiness_runner=$!
  ship_wait_until test -f "$tmp/noise-ready" || { cat "$tmp/run.log" >&2; exit 1; }
  # Hold the lock only after the editor has started and the pre-run snapshot is done.
  (set -C; printf 'fixture-owned\n' > "$lock")
  bash "$script" stop > "$tmp/stop.log" 2>&1 || { cat "$tmp/stop.log" >&2; exit 1; }
  wait "$readiness_runner" 2>/dev/null || true
  cleanup_readiness_runner
  check "$command: stop leaves the foreign index lock in place and attempts noise cleanup" \
    '[ "$(cat "$lock")" = fixture-owned ] && grep -Fq "retrying up to 2 times" "$tmp/run.log"'
  check "$command: stop returns the licence and releases the seat despite locked cleanup" \
    'grep -Fxq -- --return-ulf "$tmp/lc-calls" && [ ! -e "$ULF" ] && [ "$(calls release)" = 1 ] && [ ! -e "$state" ]'
  rm "$lock"
  git -C "$proj" checkout -- "$settings"

  # A return failure may not replace an existing editor failure.
  reset 200
  printf '%s\n' "$good_ulf" > "$ULF"
  lu "${hub[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=42 FAKE_RETURN_RC=5 -- "$command"
  check "$command: failed licence return preserves the editor exit status" \
    '[ "$rc" = 42 ] && grep -Fq "licence return failed (exit 5)" "$tmp/log"'
done

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
