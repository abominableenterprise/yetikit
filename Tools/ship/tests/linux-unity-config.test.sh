#!/usr/bin/env bash
# Required consumer configuration keys, using a synthetic project.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

for key in schema unityVersion build build.devMethod build.releaseMethod build.apkPath scene.steps scene.lightmapDir; do
  invalid "del(.$key)" "$key"
done
config_finish
