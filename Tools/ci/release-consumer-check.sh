#!/usr/bin/env bash
# Build one clean Android dev consumer of the candidate checkout.
set -euo pipefail
ci="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$ci/../.." && pwd)"
if (( $# != 0 )); then
  echo "Usage: $0 (run from a checkout of the release candidate)" >&2
  exit 2
fi

project="$(mktemp -d "${TMPDIR:-/tmp}/yetikit-release-consumer.XXXXXX")"
project="$(cd -- "$project" && pwd -P)"
echo "[release-consumer] project and build log: $project (remove after inspection)"
mkdir -p "$project/Assets/Editor" "$project/Packages" "$project/ProjectSettings"
python3 -B "$ci/release-consumer-manifest.py" > "$project/Packages/manifest.json"
cp "$ci/ReleaseConsumerBuild.cs" "$project/Assets/Editor/"
cp "$root/Host/ProjectSettings/ProjectVersion.txt" "$project/ProjectSettings/"
# Copy player defaults, not the Host assets, package manifest or lockfile.
cp "$root/Host/ProjectSettings/ProjectSettings.asset" "$project/ProjectSettings/"
jq '.build = {
  devMethod: "ReleaseConsumerBuild.DevelopmentApk",
  releaseMethod: "ReleaseConsumerBuild.DevelopmentApk",
  apkPath: "Builds/Android/consumer.apk"
}' "$root/Host/yetikit.json" > "$project/yetikit.json"

export PROJECT="$project" YETIKIT_CONFIG="$project/yetikit.json" OUT_DIR="$project/build"
# Force a clean resolution and avoid publishing a throwaway Library cache.
export TASK_CACHE="$project/disabled-task-cache"
exec "$root/Tools/ship/linux-unity.sh" apk dev
