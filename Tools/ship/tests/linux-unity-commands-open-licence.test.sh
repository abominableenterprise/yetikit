#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# Open credential preflight and corrupt/truncated ULF recovery with a fake editor.
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands-open-licence.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

echo garbage > "$ULF"
check "open: a corrupt ULF without credentials fails before licence validation or an editor run" \
  ': > "$tmp/runs"; ! UNITY_USERNAME= UNITY_PASSWORD= lu open && grep -Fxq "[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)" "$tmp/err" && [ "$(cat "$ULF")" = garbage ] && [ ! -s "$tmp/runs" ]'
check "open: a corrupt ULF with credentials re-activates once, then opens" \
  'creds lu open && grep -q "re-activating once" "$tmp/err" && grep -q "<Signature" "$ULF"'
good_ulf | head -c 70 > "$ULF"
check "open: a truncated ULF without credentials fails before validation or the editor" \
  ': > "$tmp/runs"; ! UNITY_USERNAME= UNITY_PASSWORD= lu open && grep -Fxq "[linux-unity] error: set UNITY_USERNAME/UNITY_PASSWORD (or pass the Unity secret_fields to the task)" "$tmp/err" && [ ! -s "$tmp/runs" ]'
check "open (ensure_licence): a ULF truncated inside <Signature with credentials re-activates once, then opens" \
  'creds lu open && grep -q "is truncated.*re-activating once" "$tmp/err" && grep -q "</Signature>" "$ULF"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
