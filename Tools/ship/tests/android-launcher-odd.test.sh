#!/usr/bin/env bash
# Complementary deterministic half of the launcher subprocess checks.
export LAUNCHER_TEST_SHARD=1
. "$(dirname "$0")/android-launcher.test.sh"
