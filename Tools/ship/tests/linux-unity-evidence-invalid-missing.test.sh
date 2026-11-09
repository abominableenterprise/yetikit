#!/usr/bin/env bash
# Synthetic editor regressions: evidence invalid-missing.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

evidence_filtered_invalid no-file empty
evidence_implicit_invalid no-file empty

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
