#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"
invalid '.tests.prPure = null' tests.prPure
for value in '"Fixture"' '["A;B"]' '[false]' '["A\nB"]'; do
  invalid ".tests.prPure.smokeFixtures = $value" tests.prPure.smokeFixtures
done
for value in '"8"' '-1' '1.5' '10000000'; do
  invalid ".tests.prPure.max = $value" tests.prPure.max
done
for value in 'false' '""' '"["'; do
  invalid ".tests.prPure.fallbackRegex = $value" tests.prPure.fallbackRegex
done
jq '.tests.prPure = {smokeFixtures:[], max:0, fallbackRegex:"^ci/"}' "$tmp/scene.json" > "$proj/yetikit.json"
bash -c '. "$1"' _ "$script"
check 'valid pure config accepted' '[ ! -f "$tmp/runs" ]'
config_finish
