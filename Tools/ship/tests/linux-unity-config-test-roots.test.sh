#!/usr/bin/env bash
# Test and EditMode root validation: all five original values for each root.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

config_test_roots root editModeRoot
config_finish
