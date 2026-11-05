#!/usr/bin/env bash
# Synthetic consumer projects vendor the shell tools before invoking them.
SHIP_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIP_SOURCE_DIR="$(cd "$SHIP_TESTS_DIR/.." && pwd)"
ship_fixture() {
  local project="$1" variant="${2:-scene}" file
  mkdir -p "$project/Tools/ship"
  for file in "$SHIP_SOURCE_DIR"/*.sh; do
    cp "$file" "$project/Tools/ship/"
  done
  if [ -d "$SHIP_SOURCE_DIR/lib" ]; then cp -R "$SHIP_SOURCE_DIR/lib" "$project/Tools/ship/"; fi
  cp "$SHIP_TESTS_DIR/fixtures/$variant/yetikit.json" "$project/yetikit.json"
  cp "$SHIP_TESTS_DIR/fixtures/known-flakes.txt" "$project/Tools/ship/known-flakes.txt"
  export PROJECT="$project" PIDFILE_FALLBACK="${PIDFILE_FALLBACK:-$project/fallback.pid}"
  script="$project/Tools/ship/linux-unity.sh"
}
