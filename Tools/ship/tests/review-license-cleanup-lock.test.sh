#!/usr/bin/env bash
# A surviving licensing child must not inherit the editor cleanup flock.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; child=''
trap '[ -z "$child" ] || { kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; }; rm -rf "$tmp"' EXIT
. "$here/linux-unity-license.sh"
exec {UNITY_CLEANUP_FD}> "$tmp/cleanup.lock"
flock -n "$UNITY_CLEANUP_FD"
( licensing_close_locks; exec sleep 30 ) & child=$!
exec {UNITY_CLEANUP_FD}>&-
# Child is deliberately still live: lock availability must not depend on its exit.
kill -0 "$child"
flock -w 2 "$tmp/cleanup.lock" true
printf 'PASS: surviving licensing child cannot retain Unity cleanup lock\n'
