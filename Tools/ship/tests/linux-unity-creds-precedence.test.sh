#!/usr/bin/env bash
# Synthetic editor regressions: creds precedence.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-creds-fixture.sh
. "$(dirname "$0")/lib/linux-unity-creds-fixture.sh"

args=(return)
good_ulf_now
lu UNITY_USERNAME=u@x.io UNITY_PASSWORD=unity-secret USERNAME=hubuser@x.io PASSWORD=hub-secret
check "UNITY_USERNAME/UNITY_PASSWORD win over USERNAME/PASSWORD" \
  '[ "$rc" = 0 ] && grep -qx -- "--return-ulf --username u@x.io --password unity-secret" "$tmp/lc-calls" && ! leaks'
good_ulf_now
lu UNITY_USERNAME= UNITY_PASSWORD= USERNAME=hubuser@x.io PASSWORD=hub-secret
check "empty UNITY_USERNAME/UNITY_PASSWORD fall back to USERNAME/PASSWORD" \
  '[ "$rc" = 0 ] && grep -q -- "--username hubuser@x.io" "$tmp/lc-calls"'
good_ulf_now
lu USERNAME=hubuser@x.io
check "USERNAME without PASSWORD: no fallback, the usual error" \
  '[ "$rc" != 0 ] && grep -Fxq "$creds_error" "$tmp/log" && [ ! -s "$tmp/lc-calls" ] && [ -f "$ULF" ] && ! leaks'


[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
