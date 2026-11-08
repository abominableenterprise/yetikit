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
  mkdir -p "$project/Tools/ship" "$project/.ship-test-bin"
  # Preserve synthetic commands/environment without invoking real sudo, even standalone.
  printf '#!/bin/sh\nexec "$@"\n' > "$project/.ship-test-bin/sudo"
  chmod +x "$project/.ship-test-bin/sudo"
  export PATH="$project/.ship-test-bin:$PATH"
  for file in "$SHIP_SOURCE_DIR"/*.sh; do
    cp "$file" "$project/Tools/ship/"
  done
  if [ -d "$SHIP_SOURCE_DIR/lib" ]; then cp -R "$SHIP_SOURCE_DIR/lib" "$project/Tools/ship/"; fi
  cp "$SHIP_TESTS_DIR/fixtures/$variant/yetikit.json" "$project/yetikit.json"
  cp "$SHIP_TESTS_DIR/fixtures/known-flakes.txt" "$project/Tools/ship/known-flakes.txt"
  export PROJECT="$project" PIDFILE_FALLBACK="${PIDFILE_FALLBACK:-$project/fallback.pid}"
  script="$project/Tools/ship/linux-unity.sh"
}
