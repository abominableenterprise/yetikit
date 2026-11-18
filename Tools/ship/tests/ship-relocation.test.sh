#!/usr/bin/env bash
# Run both entry points from a copied tool directory in a synthetic project.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
. "$ship/tests/lib/quest-release-config.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
qr_test_config "$tmp/project"
cd "$tmp/project"
mkdir tooling
cp -R "$ship" tooling/release
export PROJECT="$PWD" UNITY_ROOT="$tmp/no-editor" OUT_DIR="$tmp/build"
export UNITY_USERNAME=fixture UNITY_PASSWORD=fixture QUEST_LOG_ROOT="$tmp/logs"

expect() {
  local status="$1" line="$2" rc=0
  shift 2
  bash "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" != "$status" ] || ! grep -Fq -- "$line" "$tmp/out" "$tmp/err"; then
    printf 'FAIL: %s (exit %s, expected %s); expected %s\n' "$*" "$rc" "$status" "$line" >&2
    cat "$tmp/out" "$tmp/err" >&2
    return 1
  fi
  printf 'ok: %s\n' "$line"
}

# Already relative on main: only the hard-coded help text needs fixing on Linux.
expect 1 'run `tooling/release/linux-unity.sh setup` first' tooling/release/linux-unity.sh activate
failed=0
expect 2 'Usage: tooling/release/linux-unity.sh <command>' tooling/release/linux-unity.sh --help || failed=1
expect 0 'Usage: tooling/release/quest-release.sh <command>' tooling/release/quest-release.sh --help || failed=1
expect 1 "run 'tooling/release/quest-release.sh prepare [<ref>]' first" tooling/release/quest-release.sh gate || failed=1
[ "$failed" = 0 ]
