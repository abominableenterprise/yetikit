#!/usr/bin/env bash
# Noise and font-asset configuration validation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

while IFS='|' read -r expression key; do
  invalid "$expression" "$key"
done <<'EOF'
.noise = []|noise
.noise.atlasPath = 42|noise.atlasPath
.noise.artRoot = null|noise.artRoot
.noise.artRoot = ""|noise.artRoot
.noise.artRoot = "/outside"|noise.artRoot
.noise.artRoot = "Assets/../outside"|noise.artRoot
.noise.artRoot = "././"|noise.artRoot
.noise.artRoot = "Assets/line\nbreak"|noise.artRoot
.noise.protecedRegex = "^Assets/"|noise.protecedRegex
.noise.fontAssetPaths = null|noise.fontAssetPaths
.noise.fontAssetPaths = "Assets/Fonts/Static.asset"|noise.fontAssetPaths
.noise.fontAssetPaths = [42]|noise.fontAssetPaths
.noise.fontAssetPaths = [""]|noise.fontAssetPaths
.noise.fontAssetPaths = ["/outside.asset"]|noise.fontAssetPaths
.noise.fontAssetPaths = ["../outside.asset"]|noise.fontAssetPaths
.noise.fontAssetPaths = ["Assets/Fonts/line\nbreak.asset"]|noise.fontAssetPaths
EOF

for key in protectedRegex sourceRegex generatorsRegex codeRegex repackRegex; do
  invalid ".noise.$key = \"[\"" "noise.$key"
done
# A jq lookahead is not a Bash ERE.
invalid '.noise.protectedRegex = "(?=Assets/)"' noise.protectedRegex

config_no_scene_files
for fixture in "$SHIP_TESTS_DIR"/fixtures/*/yetikit.json; do
  cp "$fixture" "$proj/yetikit.json"
  run cache-key
  check "accepts ${fixture%/yetikit.json} config" '[ "$rc" = 0 ] && [ ! -f "$tmp/runs" ]'
done
config_finish
