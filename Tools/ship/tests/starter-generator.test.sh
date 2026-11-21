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
python3 -B - "$out/game/Assets/Starter/Impact.wav" <<'PY'
import struct
import sys
import wave

with wave.open(sys.argv[1], "rb") as clip:
    assert (clip.getnchannels(), clip.getsampwidth()) == (1, 2), "Expected mono 16-bit PCM"
    count = clip.getnframes()
    assert 0.15 <= count / clip.getframerate() <= 0.25, "Expected a short, audible cue"
    samples = struct.unpack(f"<{count}h", clip.readframes(count))
    assert 16384 <= max(map(abs, samples)) < 32767, "Expected a strong, unclipped peak"
PY
grep -Fq '## Day-0 checklist' "$readme"
test "$(grep -Ec '^[0-9]+\. \*\*' "$readme")" = 10
grep -Fq 'pending separate headset validation' "$readme"
grep -Eq '≤2 hours.*≤4 hours.*unmeasured' "$readme"
python3 -B "$repo/Tools/ship/tests/starter-package-sources.py" "$out/game"

# Opt in by running this fixture directly after activating Unity. CI stays offline.
if [[ ${STARTER_COMPILE:-0} == 1 ]]; then
    project="$out/standalone"
    python3 "$repo/templates/game/new-game.py" --id org.examplechecks.sandbox --title 'Neutral Fixture' --out "$project"
    PROJECT="$project" YETIKIT_CONFIG="$repo/Host/yetikit.json" OUT_DIR="$project/build" \
        TASK_CACHE=skip-unity-library-cache SEAT_STATE="${SEAT_STATE:-$repo/Host/build/unity-seat.held}" \
        "$repo/Tools/ship/linux-unity.sh" open || {
        grep -E 'error CS[0-9]+|\[Package Manager\].*[Ee]rror' "$project/build/open.log" >&2 || true
        exit 1
    }
    python3 -B "$project/verify-packages.py"
    test -f "$project/Library/ScriptAssemblies/Game.Starter.Editor.dll"
    test -f "$project/Library/ScriptAssemblies/Game.Dev.dll"
fi
