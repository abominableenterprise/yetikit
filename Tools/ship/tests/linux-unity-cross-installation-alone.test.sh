#!/usr/bin/env bash
# Global shared memory checks across synthetic installation roots.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-cross-installation-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-cross-installation-fixture.sh"

cross_installation_scenarios alone
[ "$failures" = 0 ]
