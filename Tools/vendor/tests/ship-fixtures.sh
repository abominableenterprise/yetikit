#!/usr/bin/env bash
# Exercise the real fixture sources from a consumer-owned, non-default path.
set -euo pipefail
vendor="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vendored ship fixtures.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
consumer="$tmp/consumer"
mkdir -p "$consumer/Tools/yetikit"
cp -R "$vendor/../ship/." "$consumer/Tools/yetikit/"
[ ! -e "$consumer/Tools/ship" ]
cd "$consumer"
bash Tools/yetikit/tests/run.sh linux-unity-apk.test.sh quest-release-fixture-safety.test.sh
printf 'PASS: vendored Ship fixture regressions\n'
