#!/usr/bin/env bash
# Exercise aggregate selection in a synthetic checkout, never the real suite.
set -euo pipefail
ship="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Tools/ship/tests/lib" "$tmp/.github/workflows"
cp "$ship/test-all.sh" "$tmp/Tools/ship/test-all.sh"
printf '#!/bin/bash\necho selected >> "$SELECTION_LOG"\n' > "$tmp/Tools/ship/tests/sample.test.sh"
printf 'base\n' > "$tmp/Tools/ship/tests/lib/fixture.sh"
printf 'base\n' > "$tmp/.github/workflows/ship.yml"
git -C "$tmp" init -q -b main
git -C "$tmp" add .
git -C "$tmp" -c user.name=t -c user.email=t@t commit -qm base
git -C "$tmp" update-ref refs/remotes/origin/main HEAD
export SELECTION_LOG="$tmp/selected" TEST_JOBS=1
run() { bash "$tmp/Tools/ship/test-all.sh" "$@" > "$tmp/output" 2>&1; }
run
[ ! -e "$SELECTION_LOG" ] && grep -q 'no tests selected' "$tmp/output"
printf 'unrelated\n' > "$tmp/mesh.py"
run
[ ! -e "$SELECTION_LOG" ] && grep -q 'no tests selected' "$tmp/output"
echo 'ok   unchanged Ship and unrelated changes skip the suite'
printf 'changed\n' >> "$tmp/Tools/ship/tests/lib/fixture.sh"
run
[ "$(wc -l < "$SELECTION_LOG")" = 1 ]
echo 'ok   shared fixture changes select the suite'
git -C "$tmp" restore Tools/ship/tests/lib/fixture.sh
printf 'changed\n' >> "$tmp/.github/workflows/ship.yml"
run
[ "$(wc -l < "$SELECTION_LOG")" = 2 ]
echo 'ok   workflow changes select the suite'
git -C "$tmp" restore .github/workflows/ship.yml
printf 'new\n' > "$tmp/Tools/ship/tests/lib/new-fixture"
run
[ "$(wc -l < "$SELECTION_LOG")" = 3 ]
echo 'ok   untracked shared fixtures select the suite'
rm "$tmp/Tools/ship/tests/lib/new-fixture"
run --all
[ "$(wc -l < "$SELECTION_LOG")" = 4 ]
echo 'ok   explicit --all runs an unchanged suite'
