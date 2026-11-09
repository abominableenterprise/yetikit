#!/usr/bin/env bash
# Noise and font-asset configuration validation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

while IFS='|' read -r expression key; do
  invalid "$expression" "$key"
done <<'EOF'
.noise = []|noise
.noise.atlasPath = 42|noise
.noise.fontAssetPaths = null|noise.fontAssetPaths
.noise.fontAssetPaths = "Assets/Fonts/Static.asset"|noise.fontAssetPaths
.noise.fontAssetPaths = [42]|noise.fontAssetPaths
.noise.fontAssetPaths = [""]|noise.fontAssetPaths
.noise.fontAssetPaths = ["/outside.asset"]|noise.fontAssetPaths
.noise.fontAssetPaths = ["../outside.asset"]|noise.fontAssetPaths
.noise.fontAssetPaths = ["Assets/Fonts/line\nbreak.asset"]|noise.fontAssetPaths
EOF
config_finish
