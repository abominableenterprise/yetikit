#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
echo '[starter-generator] worker started'
bash "$repo/Host/StarterTests/stage.sh" --check-only
