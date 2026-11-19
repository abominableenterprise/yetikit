#!/usr/bin/env bash
set -euo pipefail
exec python3 -B "$(dirname "$0")/helpers/linux-unity-setup-cancel.py" "$@"
