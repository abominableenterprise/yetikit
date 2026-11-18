#!/usr/bin/env bash
# Synthetic runner scheduling/lifecycle checks; never runs Unity or writes an index.
set -euo pipefail
here="$(dirname "$0")"
. "$here/lib/fixture.sh"
# Keep one writer open while checking readiness at each publication stage.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
exec 8> "$tmp/delayed.pid"
if ship_read_pid "$tmp/delayed.pid"; then echo 'empty PID reported ready' >&2; exit 1; fi
printf 4 >&8
if ship_read_pid "$tmp/delayed.pid"; then echo 'partial PID reported ready' >&2; exit 1; fi
printf '242\n' >&8
[ "$(ship_read_pid "$tmp/delayed.pid")" = 4242 ]
exec 8>&-
echo 'ok   shell: delayed PID write'
python3 -B "$here/helpers/runner-regressions.py"
