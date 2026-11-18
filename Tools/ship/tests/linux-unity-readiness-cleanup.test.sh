#!/usr/bin/env bash
# Run only synthetic stop and activation readiness-failure cases in a disposable copy.
set -euo pipefail
exec python3 -B "$(dirname "$0")/helpers/linux-unity-readiness-cleanup.py" "$@"
