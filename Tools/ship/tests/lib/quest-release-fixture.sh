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

# Flow fixtures opt in: every readiness owner is a direct child of the suite.
# Register before polling, so even a failed handshake has an EXIT cleanup owner.
qr_fixture_wait_ready() {
  local file="$1" owner="$2" deadline=$((SECONDS + 60))
  if [ "${QR_FIXTURE_MANAGE_CHILDREN:-0}" = 1 ] && [ "$owner" != "$$" ]; then
    case " ${QR_FIXTURE_OWNED_PIDS:-} " in
      *" $owner "*) ;;
      *) QR_FIXTURE_OWNED_PIDS="${QR_FIXTURE_OWNED_PIDS:-} $owner" ;;
    esac
  fi
  while [ ! -f "$file" ]; do
    if ! kill -0 "$owner" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; then
      echo "fixture readiness failed: $file (owner $owner)" >&2
      return 1
    fi
    command sleep 0.05
  done
}

# Only signal still-owned jobs: a normally reaped PID may already have been reused.
# The synthetic blockers/editors trap TERM and reap their own sleep children.
qr_fixture_cleanup_children() {
  local pid jobs remaining deadline=$((SECONDS + 2))
  jobs=" $(jobs -p | tr '\n' ' ') "
  for pid in ${QR_FIXTURE_OWNED_PIDS:-}; do
    case "$jobs" in *" $pid "*) kill -TERM "$pid" 2>/dev/null || true ;; esac
  done
  while :; do
    remaining=''; jobs=" $(jobs -pr | tr '\n' ' ') "
    for pid in ${QR_FIXTURE_OWNED_PIDS:-}; do
      case "$jobs" in *" $pid "*) remaining="$remaining $pid" ;; esac
    done
    [ -n "$remaining" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      for pid in $remaining; do kill -KILL "$pid" 2>/dev/null || true; done
      break
    fi
    builtin command sleep 0.05
  done
  for pid in ${QR_FIXTURE_OWNED_PIDS:-}; do wait "$pid" 2>/dev/null || true; done
  QR_FIXTURE_OWNED_PIDS=''
}

# A synthetic editor/blocker owns exactly one sleep at a time. Use an executable:
# command() and background builtins otherwise make $! own a wrapper, not sleep.
# TERM can arrive after the fork but before child=$!: include the latest PID too.
# Publish readiness only after the trap and child metadata are installed.
qr_fixture_block_until_term() {
  local marker="$1" child=''
  trap 'trap "" TERM; kill "$child" "${!:-}" 2>/dev/null; wait "$child" 2>/dev/null; wait "${!:-}" 2>/dev/null; : > "$marker.terminated"; exit 143' TERM
  while :; do
    /bin/sleep 3600 & child=$!
    printf '%s\n' "$child" > "$marker.child"
    : > "$marker.started"
    wait "$child"
  done
}

# Bound a broken cancellation without making successful tests wait. The timer is reaped on disarm.
qr_fixture_watchdog() {
  local owner="$1" timer=""
  trap 'kill "$timer" "${!:-}" 2>/dev/null; wait "$timer" 2>/dev/null; wait "${!:-}" 2>/dev/null; exit' TERM
  /bin/sleep 60 & timer=$!
  wait "$timer"
  kill -KILL "$owner" 2>/dev/null
}
