#!/usr/bin/env bash
# Synthetic editor regressions: creds return-open.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-creds-fixture.sh
. "$(dirname "$0")/lib/linux-unity-creds-fixture.sh"

# --- UNITY_RETURN_ON_EXIT=1 ----------------------------------------------------------------------------------------
creds=(UNITY_USERNAME=u@x.io UNITY_PASSWORD=unity-secret)
returns() { grep -c -- "^--return-ulf" "$tmp/lc-calls" || true; }
args=(open); rm -f "$ULF"
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1 FAKE_UNITY_RC=1
check "UNITY_RETURN_ON_EXIT=1: a failed open that activated returns the licence and keeps its failure" \
  '[ "$rc" = 1 ] && grep -q -- "^--activate-ulf" "$tmp/lc-calls" && [ "$(returns)" = 1 ] && grep -q "returning the held licence" "$tmp/log" && [ ! -f "$ULF" ]'
check "UNITY_RETURN_ON_EXIT=1: the pidfile is gone afterwards" '[ ! -f "$OUT_DIR/linux-unity.pid" ]'
rm -f "$ULF"
lu USERNAME=hubuser@x.io PASSWORD=hub-secret UNITY_RETURN_ON_EXIT=1
check "UNITY_RETURN_ON_EXIT=1 with the USERNAME/PASSWORD fallback: an open that activated returns, printing neither" \
  '[ "$rc" = 0 ] && grep -qx -- "--return-ulf --username hubuser@x.io --password hub-secret" "$tmp/lc-calls" && ! leaks'
rm -f "$ULF"
lu "${creds[@]}" FAKE_UNITY_RC=1
check "without UNITY_RETURN_ON_EXIT: an open that activated keeps the licence" \
  '[ "$rc" = 1 ] && grep -q -- "^--activate-ulf" "$tmp/lc-calls" && [ "$(returns)" = 0 ]'
lu "${creds[@]}" UNITY_RETURN_ON_EXIT=1
check "UNITY_RETURN_ON_EXIT=1: a reused valid ULF is returned without activation" \
  '[ "$rc" = 0 ] && ! grep -q -- "^--activate-ulf" "$tmp/lc-calls" && [ "$(returns)" = 1 ] && [ ! -f "$ULF" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
