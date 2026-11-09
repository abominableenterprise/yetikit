#!/usr/bin/env bash
# test-all: slow linux-unity.sh
# Real open-command duration-string and disabled-limit checks.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
. "$(dirname "$0")/lib/linux-unity-timeout-real-limits.sh"
real_limits UNITY_TIMEOUT
