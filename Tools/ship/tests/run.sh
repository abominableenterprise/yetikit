#!/usr/bin/env bash
# Run isolated shell regressions in bounded slots; serial-tagged tests run alone.
# Optional arguments select test basenames for focused runs with the same CI isolation.
set -euo pipefail
suite_started=$SECONDS
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_files=("$tests"/*.test.sh)
if [ "$#" -gt 0 ]; then
  test_files=()
  for name in "$@"; do
    case "$name" in */*) printf 'invalid test basename: %s\n' "$name" >&2; exit 1 ;; esac
    case "$name" in *.test.sh) ;; *) printf 'invalid test basename: %s\n' "$name" >&2; exit 1 ;; esac
    [ -f "$tests/$name" ] || { printf 'missing test: %s\n' "$name" >&2; exit 1; }
    test_files+=("$tests/$name")
  done
fi
for dependency in bash jq python3 perl git xmllint timeout flock sha256sum; do
  command -v "$dependency" >/dev/null || { printf 'missing test dependency: %s\n' "$dependency" >&2; exit 1; }
done
# GNU timeout's process-group KILL behavior is required by the lifecycle regressions.
if ! timeout --version | grep -qF 'GNU coreutils'; then
  printf 'missing test dependency: GNU coreutils timeout\n' >&2
  exit 1
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/jq-cache"
export SHIP_TEST_REAL_JQ="$(command -v jq)" SHIP_TEST_JQ_CACHE="$tmp/jq-cache"
export SHIP_TEST_ORIGINAL_JQ="$SHIP_TEST_REAL_JQ"
cp "$tests/lib/config-jq-cache.py" "$tmp/bin/jq"
for command in curl wget crane task-cache apt-get swapon swapoff mkswap fallocate; do
  printf '#!/bin/sh\nprintf "unexpected external command: %s\\n" >&2\nexit 99\n' "$command" > "$tmp/bin/$command"
done
# Production as_root must use the fixture PATH even on an unprivileged CI worker.
printf '#!/bin/sh\nexec "$@"\n' > "$tmp/bin/sudo"
chmod +x "$tmp/bin/"*
cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
((cpus >= 1)) || cpus=1
((cpus <= 8)) || cpus=8
jobs="${SHIP_TEST_JOBS-$cpus}"
case "$jobs" in 1|2|3|4|5|6|7|8) ;; *) echo 'SHIP_TEST_JOBS must be 1 through 8' >&2; exit 1 ;; esac
failed=0; passed=0
: > "$tmp/durations"
pids=(); names=(); active=0
cleanup() {
  local pid groups grace_started alive
  trap '' INT TERM
  groups="$(ps -axo pid=,ppid=,pgid= | awk -v roots="${pids[*]-}" '
    {parent[$1]=$2; group[$1]=$3}
    function owned(p) {
      if (p in root) return 1
      if (!(p in parent) || parent[p] == p) return 0
      return owned(parent[p])
    }
    END {
      n=split(roots, ids, " ")
      for (i=1; i<=n; i++) if (ids[i] != "") root[ids[i]]=1
      for (p in parent) if (owned(p)) groups[group[p]]=1
      for (p in root) groups[p]=1
      for (g in groups) print g
    }')"
  for pid in $groups; do kill -TERM -- "-$pid" 2>/dev/null || true; done
  # Keep the pre-TERM snapshot even after worker/timeout parents exit: their
  # TERM-ignoring descendants may now be orphans in separate process groups.
  grace_started=$SECONDS
  while ((SECONDS - grace_started < 2)); do
    alive=0
    for pid in $groups; do
      if kill -0 -- "-$pid" 2>/dev/null; then alive=1; break; fi
    done
    ((alive)) || break
    sleep 0.1
  done
  for pid in $groups; do kill -KILL -- "-$pid" 2>/dev/null || true; done
  for pid in ${pids[@]+"${pids[@]}"}; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Each worker owns its process group. Per-file timeout retains its own bounded
# process-group escalation, as in the sequential runner.
set -m
run_test() {
  local test="$1" name="${1##*/}" test_started=$SECONDS status=0 elapsed
  set +m
  mkdir -p "$tmp/$name"/{home,tmp,shm,config,cache,data,state}
  printf '\n=== %s ===\n' "$name"
  (
    for variable in ${!UNITY_@} ${!THEROBOTS_@} ${!FAKE_@} ${!APK_@} ${!NOISE_@} ${!IDLE_@} ${!SEAT_@} ${!QUEST_@} ${!QR_@}; do unset "$variable"; done
    unset PROJECT YETIKIT_CONFIG USERNAME PASSWORD ULF OUT_DIR PIDFILE PIDFILE_FALLBACK BIN_DIR \
      KNOWN_FLAKES SCENE_AREAS EDITMODE_GFX TASK_CACHE MEMINFO TEST_PR_GFX_MAX \
      FOLLOWUPS_TEST_SCRIPT SHARED_IDLE_TEST_SCRIPT PIDFILE_TEST_SCRIPT WATCHER_CASE \
      SHIP_CONFIG_FILE SHIP_CONFIG_LOADED GIT_DIR GIT_WORK_TREE
    export HOME="$tmp/$name/home" TMPDIR="$tmp/$name/tmp" PATH="$tmp/bin:$PATH" SHM_DIR="$tmp/$name/shm" \
      XDG_CONFIG_HOME="$tmp/$name/config" XDG_CACHE_HOME="$tmp/$name/cache" \
      XDG_DATA_HOME="$tmp/$name/data" XDG_STATE_HOME="$tmp/$name/state" \
      PIDFILE_FALLBACK="$tmp/$name/fallback.pid" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    cd "$tests"
    timeout -k 10 600 bash +m -c '
      cancel() { trap "" INT TERM; exit "$1"; }
      trap "cancel 143" TERM
      trap "cancel 130" INT
      source "$0"
    ' "$test"
  ) || status=$?
  elapsed=$((SECONDS - test_started))
  printf 'Elapsed: %s (%s s)\n' "$name" "$elapsed"
  printf '%s\t%s\n' "$elapsed" "$name" > "$tmp/$name/duration"
  return "$status"
}
launch() {
  local index=${#pids[@]} name="${1##*/}"
  run_test "$1" > "$tmp/$name.log" 2>&1 &
  pids[index]=$!; names[index]="$name"
  active=$((active + 1))
}
reap() {
  local i status found=0
  for ((i=0; i<${#pids[@]}; i++)); do
    [ -n "${pids[i]}" ] || continue
    if kill -0 "${pids[i]}" 2>/dev/null; then continue; fi
    status=0; wait "${pids[i]}" || status=$?
    pids[i]=''; active=$((active - 1)); found=1
    cat "$tmp/${names[i]}.log"
    if [ "$status" = 0 ]; then passed=$((passed + 1));
    else printf 'FAILED: %s (exit %s)\n' "${names[i]}" "$status" >&2; failed=$((failed + 1)); fi
    [ ! -f "$tmp/${names[i]}/duration" ] || cat "$tmp/${names[i]}/duration" >> "$tmp/durations"
  done
  ((found)) || sleep 0.1
}
serial=()
for test in "${test_files[@]}"; do
  if grep -q '^# test-all: serial[[:space:]]*$' "$test"; then serial+=("$test"); continue; fi
  while ((active >= jobs)); do reap; done
  launch "$test"
done
while ((active)); do reap; done
# Always run serial-tagged files after the parallel batch, even with one slot.
for test in ${serial[@]+"${serial[@]}"}; do
  launch "$test"
  while ((active)); do reap; done
done
printf '\n%d test scripts passed; %d failed\n' "$passed" "$failed"
printf 'Total duration: %s s\n' "$((SECONDS - suite_started))"
printf 'Slowest 5 files (seconds):\n'
sort -k1,1nr -k2,2 "$tmp/durations" | awk 'NR <= 5 {printf "  %ss %s\n", $1, $2}'
[ "$failed" = 0 ]
