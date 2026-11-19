#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
echo '[starter-generator] worker started'
bash "$repo/Host/StarterTests/stage.sh" --check-only

out=$(mktemp -d)
trap 'rm -rf -- "$out"' EXIT
python3 "$repo/templates/game/new-game.py" --id org.examplechecks.sandbox --title 'Neutral Fixture' --out "$out/game"
readme="$out/game/README.md"
test -f "$out/game/Assets/Starter/Editor/StarterPlayerBuild.cs"
grep -Fq '## Day-0 checklist' "$readme"
test "$(grep -Ec '^[0-9]+\. \*\*' "$readme")" = 10
grep -Fq 'pending separate headset validation' "$readme"
grep -Eq '≤2 hours.*≤4 hours.*unmeasured' "$readme"
