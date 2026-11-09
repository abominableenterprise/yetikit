#!/usr/bin/env bash
# Synthetic editor regressions: creds return-failures.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-creds-fixture.sh
. "$(dirname "$0")/lib/linux-unity-creds-fixture.sh"

creds=(UNITY_USERNAME=u@x.io UNITY_PASSWORD=unity-secret)
returns() { grep -c -- "^--return-ulf" "$tmp/lc-calls" || true; }
args=(open)
rm -f "$ULF"
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_RETURN_RC=7
check "UNITY_RETURN_ON_EXIT=1: a failed return alone makes the run exit nonzero (its code)" \
  '[ "$rc" = 7 ] && grep -q "licence return failed (exit 7)" "$tmp/log" && [ -f "$ULF" ]'
args=(test editmode); rm -f "$ULF"
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_FAILS=X.Broken
check "UNITY_RETURN_ON_EXIT=1: a failing test run that activated returns the licence, keeps the test failure" \
  '[ "$rc" = 2 ] && [ "$(returns)" = 1 ]'
args=(all); rm -f "$ULF"; : > "$tmp/unity/.install-complete"
for c in crane dpkg ldd; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 BIN_DIR="$tmp/bin"
check "UNITY_RETURN_ON_EXIT=1 with all: one return, not two" '[ "$rc" = 0 ] && [ "$(returns)" = 1 ]'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
