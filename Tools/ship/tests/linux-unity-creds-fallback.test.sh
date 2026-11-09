#!/usr/bin/env bash
# Synthetic editor regressions: creds fallback.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-creds-fixture.sh
. "$(dirname "$0")/lib/linux-unity-creds-fixture.sh"

# --- credentials fallback ------------------------------------------------------------------------------------------
args=(activate); rm -f "$ULF"
lu USERNAME=hubuser@x.io PASSWORD=hub-secret
check "only USERNAME/PASSWORD: activate passes need_creds" '[ "$rc" = 0 ] && ! grep -q "set UNITY_USERNAME" "$tmp/log"'
check "only USERNAME/PASSWORD: the licensing client gets those values" \
  'grep -qx -- "--activate-ulf --username hubuser@x.io --password hub-secret" "$tmp/lc-calls"'
check "only USERNAME/PASSWORD: neither value is printed (the client's echo is masked)" \
  '! leaks && grep -q "<email>" "$tmp/log" && grep -q "<password>" "$tmp/log"'
args=(return)
lu USERNAME=hubuser@x.io PASSWORD=hub-secret
check "only USERNAME/PASSWORD: return passes and returns with them, printing neither" \
  '[ "$rc" = 0 ] && grep -qx -- "--return-ulf --username hubuser@x.io --password hub-secret" "$tmp/lc-calls" && ! leaks'
check "successful explicit return removes the ULF" '[ ! -e "$ULF" ]'
lu
check "return without a ULF skips credentials and the Licensing Client" \
  '[ "$rc" = 0 ] && grep -Fq "return: licence already returned" "$tmp/log" && [ ! -s "$tmp/lc-calls" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
