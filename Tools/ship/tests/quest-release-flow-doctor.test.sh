#!/usr/bin/env bash
# Isolated release-flow regressions; synthetic editor/device only, Bash 3.2 compatible.
# shellcheck disable=SC2016,SC2034 # check evaluates conditions and their fixture variables.
. "$(dirname "$0")/lib/quest-release-flow-fixture.sh"

qr_flow_build
qr_flow_keystore

# Read-only doctor regressions use only prepared worktrees, an APK and a debug keystore.
# shellcheck source=Tools/ship/tests/lib/quest-release-doctor.sh
. "$(dirname "$script")/tests/lib/quest-release-doctor.sh"


qr_flow_finish
