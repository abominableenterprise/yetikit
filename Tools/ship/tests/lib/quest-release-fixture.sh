# shellcheck shell=bash
# Shared shell-fixture synchronization; no Unity or device. Bash 3.2 compatible.

# A nested async runner may start this test with INT/QUIT ignored. Bash cannot reset signals ignored at entry,
# even with `set -m` or `trap - INT`. Reset BEFORE exec'ing a fresh Bash; exec preserves $! as the owner PID.
# Perl is already used by quest-release-wait.test.sh for portable sub-second file timestamps (including macOS).
qr_fixture_bash() {
  exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV; die "exec: $!"' bash "$@"
}

# Publish only after traps, child PID metadata and any child-specific handshake are complete.
qr_fixture_ready() {
  printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

qr_fixture_wait_ready() {
  local file="$1" owner="$2" deadline=$((SECONDS + 60))
  while [ ! -f "$file" ]; do
    if ! kill -0 "$owner" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; then
      echo "fixture readiness failed: $file (owner $owner)" >&2
      return 1
    fi
    command sleep 0.05
  done
}

# Bound a broken cancellation without making successful tests wait. The timer is reaped on disarm.
qr_fixture_watchdog() {
  local owner="$1" timer=""
  trap 'kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null; exit' TERM
  command sleep 60 & timer=$!
  wait "$timer"
  kill -KILL "$owner" 2>/dev/null
}
