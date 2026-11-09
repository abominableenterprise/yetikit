#!/usr/bin/env bash
# Consumer build and top-level configuration validation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

while IFS='|' read -r expression key; do
  invalid "$expression" "$key"
done <<'EOF'
.schema = 2|schema
.unityVersion = ""|unityVersion
.build = []|build
.build.devMethod = 7|build.devMethod
.build.releaseMethod = ""|build.releaseMethod
.build.apkPath = "../outside.apk"|build.apkPath
.build.releaseApkPath = "/outside.apk"|build.releaseApkPath
.knownFlakes = false|knownFlakes
.labMethod = []|labMethod
EOF
config_finish
