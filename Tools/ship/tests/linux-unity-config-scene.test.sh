#!/usr/bin/env bash
# Generated-scene configuration validation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

while IFS='|' read -r expression key; do
  invalid "$expression" "$key"
done <<'EOF'
.scene = null|scene
.scene.steps = []|scene.steps
.scene.steps = [42]|scene.steps
.scene.lightmapDir = "../outside"|scene.lightmapDir
.scene.areaStep = ""|scene.areaStep
.scene.areaSteps = []|scene.areaSteps
.scene.keepPaths = ["../outside"]|scene.keepPaths
.scene.areasFile = "/outside"|scene.areasFile
EOF
config_finish
