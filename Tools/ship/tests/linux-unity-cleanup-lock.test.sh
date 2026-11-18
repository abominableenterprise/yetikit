#!/usr/bin/env bash
# Synthetic shared inode; enforce mode bits even when the test runs as root.
set -euo pipefail
. "$(dirname "$0")/lib/fixture.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ship_fixture "$tmp/project"
export SHM_DIR="$tmp/shm"
mkdir "$SHM_DIR"
lock="$SHM_DIR/.linux-unity-cleanup.lock"

# The first account may have a private umask. It must publish a readable inode.
(umask 077; bash -c '. "$1"; lock_unity' _ "$script")
rc=0
[ "$(stat -c %a "$lock")" = 644 ] || { echo 'FAIL: private umask leaked into the shared lock'; rc=1; }

# Mode 0444 models a second account with read but not write permission. Hold
# the original inode to prove the read-only opener still contends with it.
chmod 444 "$lock"
reader=(bash)
if [ "$(id -u)" = 0 ]; then
  reader=(setpriv --bounding-set=-dac_override,-dac_read_search bash)
fi
exec {held}< "$lock"
flock -x "$held"
if "${reader[@]}" -c '. "$1"; lock_unity' _ "$script" 2> "$tmp/busy" || ! grep -q 'another Unity run owns' "$tmp/busy"; then
  echo 'FAIL: read-only contender did not report a held cleanup lock'; rc=1
fi
exec {held}<&-
inode="$(stat -c %i "$lock")"
if ! "${reader[@]}" -c '. "$1"; lock_unity' _ "$script" || [ "$(stat -c %i "$lock")" != "$inode" ]; then
  echo 'FAIL: reader could not lock the existing shared inode'; rc=1
fi
exit "$rc"
