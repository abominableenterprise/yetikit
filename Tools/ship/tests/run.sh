#!/usr/bin/env bash
# Run shell regressions serially: fake editors/clients, no network or host seats.
# Optional arguments select test basenames for focused runs with the same CI isolation.
set -euo pipefail
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
mkdir -p "$tmp/bin"
for command in curl wget crane task-cache apt-get swapon swapoff mkswap fallocate; do
  printf '#!/bin/sh\nprintf "unexpected external command: %s\\n" >&2\nexit 99\n' "$command" > "$tmp/bin/$command"
done
# Production as_root must use the fixture PATH even on an unprivileged CI worker.
printf '#!/bin/sh\nexec "$@"\n' > "$tmp/bin/sudo"
chmod +x "$tmp/bin/"*
failed=0; passed=0
for test in "${test_files[@]}"; do
  name="$(basename "$test")"
  mkdir -p "$tmp/$name/home" "$tmp/$name/shm"
  printf '\n=== %s ===\n' "$name"
  if (
    for variable in ${!UNITY_@} ${!THEROBOTS_@} ${!FAKE_@} ${!APK_@} ${!NOISE_@} ${!IDLE_@} ${!SEAT_@} ${!QUEST_@} ${!QR_@}; do unset "$variable"; done
    unset PROJECT YETIKIT_CONFIG USERNAME PASSWORD ULF OUT_DIR PIDFILE PIDFILE_FALLBACK BIN_DIR \
      KNOWN_FLAKES SCENE_AREAS EDITMODE_GFX TASK_CACHE MEMINFO TEST_PR_GFX_MAX \
      FOLLOWUPS_TEST_SCRIPT SHARED_IDLE_TEST_SCRIPT PIDFILE_TEST_SCRIPT WATCHER_CASE \
      SHIP_CONFIG_FILE SHIP_CONFIG_LOADED GIT_DIR GIT_WORK_TREE
    export HOME="$tmp/$name/home" PATH="$tmp/bin:$PATH" SHM_DIR="$tmp/$name/shm" \
      PIDFILE_FALLBACK="$tmp/$name/fallback.pid" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    cd "$tests"
    timeout -k 10 600 bash "$test"
  ); then
    passed=$((passed + 1))
  else
    printf 'FAILED: %s\n' "$name" >&2
    failed=$((failed + 1))
  fi
done
printf '\n%d test scripts passed; %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
