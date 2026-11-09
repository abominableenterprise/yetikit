#!/usr/bin/env bash
# Synthetic editor regressions: creds required-absent.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-creds-fixture.sh
. "$(dirname "$0")/lib/linux-unity-creds-fixture.sh"

creds_required_cases absent

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
