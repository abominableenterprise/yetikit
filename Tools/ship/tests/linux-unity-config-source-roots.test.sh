#!/usr/bin/env bash
# Script and editor root validation: all five original values for each root.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-config-fixture.sh"

config_test_roots scriptsRoot editorRoot
config_finish
