#!/usr/bin/env bash
# Synthetic consumer projects vendor the shell tools before invoking them.
SHIP_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIP_SOURCE_DIR="$(cd "$SHIP_TESTS_DIR/.." && pwd)"
# Poll actual readiness, never assume a loaded worker reaches a stage after a delay.
ship_wait_until() {
  local deadline=$((SECONDS + 60))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || { printf 'fixture timed out waiting for: %s\n' "$*" >&2; return 1; }
    /bin/sleep 0.02
  done
}
# Opt-in controlled executable view for replacement fixtures without real sudo.
# Only explicitly tracked synthetic PIDs use real inspection (including failures).
# Host processes are outside this model; strict scanner failure tests do not use it.
ship_fixture_process_view() {
  local bin="$1" real_readlink
  real_readlink="$(command -v readlink)"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nreal_readlink=%q\n' "$real_readlink" > "$bin/readlink"
  cat >> "$bin/readlink" <<'EOF'
if [[ "${1:-}" =~ ^/proc/([0-9]+)/exe$ ]]; then
  case " ${SHIP_FIXTURE_PIDS:-} " in
    *" ${BASH_REMATCH[1]} "*) exec "$real_readlink" "$@" ;;
    *) printf '/fixture/host-process\n'; exit 0 ;;
  esac
fi
exec "$real_readlink" "$@"
EOF
  chmod +x "$bin/readlink"
}
ship_fixture() {
  local project="$1" variant="${2:-scene}" file
  local bin="$project/.ship-test-bin" tool
  mkdir -p "$project/Tools/ship" "$bin/swap"
  # Preserve synthetic commands/environment without invoking real sudo, even standalone.
  printf '#!/bin/sh\nexec "$@"\n' > "$bin/sudo"
  # APK-specific fixtures put their opt-in swap simulations earlier in PATH.
  for tool in fallocate mkswap swapon swapoff; do
    printf '#!/bin/sh\nprintf "unexpected swap command: %s\\n" >&2\nexit 99\n' "$tool" > "$bin/$tool"
  done
  chmod +x "$bin/sudo" "$bin/"{fallocate,mkswap,swapon,swapoff}
  export PATH="$bin:$PATH" APK_SWAP_DIR="$bin/swap"
  # Keep the marker default tied to the OUT_DIR selected by each test or child.
  unset SEAT_STATE
  for file in "$SHIP_SOURCE_DIR"/*.sh; do
    cp "$file" "$project/Tools/ship/"
  done
  if [ -d "$SHIP_SOURCE_DIR/lib" ]; then cp -R "$SHIP_SOURCE_DIR/lib" "$project/Tools/ship/"; fi
  cp "$SHIP_TESTS_DIR/fixtures/$variant/yetikit.json" "$project/yetikit.json"
  cp "$SHIP_TESTS_DIR/fixtures/known-flakes.txt" "$project/Tools/ship/known-flakes.txt"
  export PROJECT="$project" PIDFILE_FALLBACK="${PIDFILE_FALLBACK:-$project/fallback.pid}"
  script="$project/Tools/ship/linux-unity.sh"
}
