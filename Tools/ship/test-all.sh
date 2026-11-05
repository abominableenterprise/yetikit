#!/usr/bin/env bash
# Run shell tests in bounded parallel slots; positional filters match basenames.
# Default: select changes since origin/main; --changed [base] changes the base.
# --all explicitly runs unchanged tests. --fast omits # test-all: slow files.
set -euo pipefail
export LC_ALL=C
ci_dir="$(cd "$(dirname "$0")" && pwd)"
shopt -s nullglob
tests=("$ci_dir"/tests/*.test.sh)
if ((${#tests[@]} == 0)); then
  echo 'ERROR: no *.test.sh files in Tools/ship/tests/' >&2
  exit 1
fi

fast=0; changed=1; base=origin/main
filters=()
while (($#)); do
  case "$1" in
    --fast) fast=1 ;;
    --all) changed=0 ;;
    --changed)
      changed=1
      if (($# > 1)) && [[ "$2" != --* ]]; then base=$2; shift; fi
      ;;
    --help|-h)
      echo 'Usage: test-all.sh [--fast] [--changed [base] | --all] [basename-filter ...]'
      exit 0 ;;
    --*) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *) filters+=("$1") ;;
  esac
  shift
done

selected=()
if ((${#filters[@]})); then
  # Validate every filter before starting any tests. Matches are literal substrings.
  for filter in "${filters[@]}"; do
    matched=0
    for test in "${tests[@]}"; do
      case "${test##*/}" in *"$filter"*) matched=1 ;; esac
    done
    if ((matched == 0)); then
      echo "ERROR: no test files match filter: $filter" >&2
      exit 1
    fi
  done
  for test in "${tests[@]}"; do
    for filter in "${filters[@]}"; do
      case "${test##*/}" in *"$filter"*) selected+=("$test"); break ;; esac
    done
  done
else
  selected=("${tests[@]}")
fi

if ((changed)); then
  repo="$(cd "$ci_dir/../.." && pwd)"
  merge_base="$(git -C "$repo" merge-base "$base" HEAD)" || {
    echo "ERROR: cannot find merge-base with $base" >&2; exit 1;
  }
  changed_paths="$(git -C "$repo" diff --name-only "$merge_base" -- Tools/ship/ .github/workflows/ship.yml)" || exit 1
  untracked="$(git -C "$repo" ls-files --others --exclude-standard -- Tools/ship/ .github/workflows/ship.yml)" || exit 1
  affected=()
  for test in ${selected[@]+"${selected[@]}"}; do
    while IFS= read -r path; do
      case "$path" in
        Tools/ship/tests/*.test.sh)
          if [ "$path" = "Tools/ship/tests/${test##*/}" ]; then affected+=("$test"); break; fi
          ;;
        Tools/ship/*|.github/workflows/ship.yml)
          affected+=("$test"); break
          ;;
      esac
    done <<< "$changed_paths
$untracked"
  done
  selected=( ${affected[@]+"${affected[@]}"} )
fi
if ((fast)); then
  quick=()
  for test in ${selected[@]+"${selected[@]}"}; do
    if ! grep -q '^# test-all: slow[[:space:]]*$' "$test"; then quick+=("$test"); fi
  done
  selected=( ${quick[@]+"${quick[@]}"} )
fi
if ((${#selected[@]} == 0)); then
  echo '[shell-test] no tests selected'
  exit 0
fi

cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
((cpus >= 1)) || cpus=1
((cpus <= 8)) || cpus=8
jobs="${TEST_JOBS-$cpus}"
case "$jobs" in
  ''|*[!0-9]*|0*) echo 'ERROR: TEST_JOBS must be a positive integer (maximum 8)' >&2; exit 1 ;;
esac
# Compare length first so excessively large settings cannot overflow shell arithmetic.
if ((${#jobs} > 1)) || ((jobs > 8)); then jobs=8; fi

file_timeout="${TEST_FILE_TIMEOUT-600}"
case "$file_timeout" in
  ''|*[!0-9]*|0*) echo 'ERROR: TEST_FILE_TIMEOUT must be a positive integer (seconds)' >&2; exit 1 ;;
esac
if ((${#file_timeout} > 9)); then
  echo 'ERROR: TEST_FILE_TIMEOUT is too large' >&2; exit 1
fi

# Give each fixture its own process group (portable Bash job control, no setsid
# dependency). Cleanup also captures descendant groups: GNU timeout creates one.
set -m
logs="$(mktemp -d)"
pids=(); starts=(); files=(); failed=(); timed_out=(); timeout_groups=()
active=0; passed=0; result=0
owned_groups() {
  # Snapshot descendants BEFORE signalling fixtures: once their parents exit,
  # timeout's separate group would be orphaned and no longer discoverable here.
  # Include the fixture groups even if their leaders have already exited.
  ps -axo pid=,ppid=,pgid= | awk -v roots="$*" '
    { parent[$1] = $2; group[$1] = $3 }
    function owned(pid) {
      if (pid in root) return 1
      if (!(pid in parent) || parent[pid] == pid) return 0
      return owned(parent[pid])
    }
    END {
      n = split(roots, ids, " ")
      for (i = 1; i <= n; i++) if (ids[i] != "") root[ids[i]] = 1
      for (pid in parent) if (owned(pid)) groups[group[pid]] = 1
      for (pid in root) groups[pid] = 1
      for (g in groups) print g
    }'
}
cleanup() {
  local pid groups index
  trap '' INT TERM
  groups="$(owned_groups "${pids[*]-}")"
  # Timeout TERM may already have orphaned descendants. Retain the pre-TERM
  # snapshot, but only for files that have not yet been collected.
  for ((index=0; index<${#pids[@]}; index++)); do
    if [ -n "${pids[index]}" ] && ((timed_out[index])); then
      groups+=" ${timeout_groups[index]}"
    fi
  done
  # Ordinary cancellation leaves shells time to run EXIT cleanup. Timed-out
  # files must still complete their existing bounded escalation before wait.
  for pid in $groups; do
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  for ((index=0; index<${#pids[@]}; index++)); do
    if [ -n "${pids[index]}" ] && ((timed_out[index])); then
      while ((SECONDS - starts[index] < file_timeout + 2)); do sleep 0.1; done
      for pid in ${timeout_groups[index]}; do
        kill -KILL -- "-$pid" 2>/dev/null || true
      done
    fi
  done
  for pid in ${pids[@]+"${pids[@]}"}; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  rm -rf "$logs"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
: > "$logs/durations"

launch() {
  local index=${#files[@]}
  files[index]="$1"
  starts[index]=$SECONDS
  timed_out[index]=0
  timeout_groups[index]=''
  # Keep the heading with its file's output, including stderr, as one complete block.
  # Source inside a fresh Bash so the TERM handler survives into the fixture.
  # An unhandled TERM skips Bash's EXIT trap. Keep $0 equal to the test path,
  # and disable job control there so its children share the fixture's group.
  local sandbox="$logs/fixture-$index"
  mkdir -p "$sandbox"/{home,project,out,unity,shm,bin,swap,config,cache,data}
  (
    echo "[shell-test] ${1##*/}"
    # Strip the caller's hub/lease state and Unity credentials before sourcing
    # tests. Fixtures can still explicitly export their own fake env afterward.
    # Prefix clearing also covers future hub secrets, not just today's token.
    for name in $(compgen -A variable THEROBOTS_) $(compgen -A variable UNITY_) \
                $(compgen -A variable SEAT_) $(compgen -A variable IDLE_) \
                $(compgen -A variable QUEST_); do
      unset "$name"
    done
    unset USERNAME PASSWORD PIDFILE LINUX_UNITY_RUN RETURN_ATTEMPTED EXIT_RC ACTIVATION_FD \
      TASK_CACHE TASK_CACHE_TIMEOUT KNOWN_FLAKES SCENE_AREAS APK_SWAPFILE YETIKIT_CONFIG
    export HOME="$sandbox/home" PROJECT="$sandbox/project" OUT_DIR="$sandbox/out" \
      UNITY_ROOT="$sandbox/unity" ULF="$sandbox/licence" SHM_DIR="$sandbox/shm" \
      BIN_DIR="$sandbox/bin" APK_SWAP_DIR="$sandbox/swap" PIDFILE_FALLBACK="$sandbox/fallback.pid" \
      XDG_CONFIG_HOME="$sandbox/config" XDG_CACHE_HOME="$sandbox/cache" XDG_DATA_HOME="$sandbox/data"
    # Leave PIDFILE/SEAT_STATE unset: their defaults must follow OUT_DIR when
    # a fixture replaces it with its own fake project/output tree.
    # Latch cancellation before entering EXIT cleanup. Nested runners and Python
    # owners may relay TERM to this group again; cleanup and its children must
    # survive that repeated signal, not re-enter the exit handler halfway through.
    exec bash +m -c '
      cancel() { trap "" INT TERM; exit "$1"; }
      trap "cancel 143" TERM
      trap "cancel 130" INT
      source "$0"
    ' "$1"
  ) > "$logs/$index" 2>&1 &
  pids[index]=$!
  active=$((active + 1))
}
# Poll rather than blocking in wait, including in one-slot and serial mode.
# TERM lets EXIT traps clean up; a bounded grace then kills the entire captured
# process tree's groups, even if a group leader has already exited.
ready() {
  local index=$1 group elapsed=$((SECONDS - starts[$1]))
  if ((timed_out[index])); then
    if ((elapsed < file_timeout + 2)); then return 1; fi
    for group in ${timeout_groups[index]}; do kill -KILL -- "-$group" 2>/dev/null || true; done
    return 0
  fi
  if ! kill -0 "${pids[index]}" 2>/dev/null; then return 0; fi
  if ((elapsed >= file_timeout)); then
    timed_out[index]=1
    timeout_groups[index]="$(owned_groups "${pids[index]}")"
    for group in ${timeout_groups[index]}; do kill -TERM -- "-$group" 2>/dev/null || true; done
  fi
  return 1
}
collect() {
  local index=$1 status=0 elapsed name
  while ! ready "$index"; do sleep 0.1; done
  wait "${pids[index]}" || status=$?
  if ((timed_out[index])); then status=124; fi
  pids[index]=''
  active=$((active - 1))
  elapsed=$((SECONDS - starts[index]))
  name="${files[index]##*/}"
  cat "$logs/$index"
  printf '%s\t%s\n' "$elapsed" "$name" >> "$logs/durations"
  if ((status)); then
    if ((timed_out[index])); then
      echo "FAIL: $name (timed out after $file_timeout s)" >&2
    else
      echo "FAIL: $name (exit $status)" >&2
    fi
    failed+=("$name")
    ((result != 0)) || result=$status
  else
    passed=$((passed + 1))
  fi
}
reap() {
  local index found=0
  for ((index=0; index<${#files[@]}; index++)); do
    if [ -n "${pids[index]}" ] && ready "$index"; then
      collect "$index"
      found=1
    fi
  done
  ((found)) || sleep 0.1
}

if ((jobs == 1)); then
  # Preserve glob order and the original fail-fast exit code in sequential mode.
  for test in "${selected[@]}"; do
    launch "$test"
    collect "$((${#files[@]} - 1))"
    ((result == 0)) || break
  done
else
  serial=()
  for test in "${selected[@]}"; do
    if grep -q '^# test-all: serial[[:space:]]*$' "$test"; then
      serial+=("$test")
      continue
    fi
    while ((active >= jobs)); do reap; done
    launch "$test"
  done
  while ((active)); do reap; done
  # Serial tests cannot overlap each other or any member of the parallel batch.
  for test in ${serial[@]+"${serial[@]}"}; do
    launch "$test"
    collect "$((${#files[@]} - 1))"
  done
fi

if ((result == 0)); then echo "[shell-test] passed $passed files"; fi
echo "[shell-test] ok $passed files; FAIL ${#failed[@]} files"
echo '[shell-test] slowest 3 files (seconds):'
sort -k1,1nr -k2,2 "$logs/durations" | awk 'NR <= 3 {printf "  %ss %s\n", $1, $2}'
if ((${#failed[@]})); then
  echo '[shell-test] failed files:' >&2
  printf '  %s\n' "${failed[@]}" >&2
fi
exit "$result"
