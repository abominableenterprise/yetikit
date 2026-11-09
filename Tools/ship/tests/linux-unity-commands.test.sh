#!/usr/bin/env bash
# test-all: serial
# Stop scans a fixture-local fallback pidfile as well as OUT_DIR.
# Activation diagnostics and existing ULF validation (fake Licensing Client only).
# Never runs Unity. Run: bash Tools/ship/tests/linux-unity-commands.test.sh
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-commands-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/linux-unity-commands-fixture.sh"

# --- #355: the missing-client error names the runnable setup command ---------------------------------------------
chmod -x "$lcdir/Unity.Licensing.Client"
check "activate: missing licensing client gives the full setup command" \
  '! creds lu activate && grep -Fxq "[linux-unity] error: licensing client not found; run \`Tools/ship/linux-unity.sh setup\` first" "$tmp/err"'
chmod +x "$lcdir/Unity.Licensing.Client"

# --- #47: activate validates an existing Unity_lic.ulf ------------------------------------------------------------
good_ulf > "$ULF"; : > "$tmp/lc-calls"
check "activate: a valid ULF is checked and kept (no re-activation)" \
  'creds lu activate && grep -q "already present.*(checked)" "$tmp/err" && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
# #145: cut-sig is a valid ULF truncated inside <Signature (both opening tags present), cut-root one cut after
# </Signature> but before the closing root element: both are invalid and take the same recovery path.
for bad in corrupt empty expired cut-sig cut-root; do
  case "$bad" in corrupt) echo garbage > "$ULF" ;; empty) : > "$ULF" ;; expired) good_ulf 2001-01-01T00:00:00 > "$ULF" ;;
    cut-sig) good_ulf | head -c 70 > "$ULF" ;; cut-root) good_ulf | sed 's#</root>##' > "$ULF" ;; esac
  rm -f "$ULF".invalid-*; : > "$tmp/lc-calls"
  check "activate: ULF ($bad) is reported, set aside and re-activated" \
    'creds lu activate && grep -q "is invalid" "$tmp/err" && grep -q -- --activate-ulf "$tmp/lc-calls" && ls "$ULF".invalid-* >/dev/null 2>&1 && grep -q "<Signature" "$ULF"'
done
good_ulf | head -c 70 > "$ULF"
check "activate: the cut-sig fixture keeps both opening tags and is reported as truncated" \
  'grep -q "<License" "$ULF" && grep -q "<Signature" "$ULF" && ! grep -q "</Signature>" "$ULF" && creds lu activate && grep -q "is invalid: truncated" "$tmp/err"'
{ printf '<?xml version="1.0" encoding="UTF-8"?>\n'; good_ulf; } > "$ULF"; : > "$tmp/lc-calls"
check "activate: a ULF with an XML declaration and a trailing newline is valid" \
  'creds lu activate && grep -q "(checked)" "$tmp/err" && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
good_ulf 2999-01-01T00:00:00 > "$ULF"; : > "$tmp/lc-calls"
check "activate: a ULF with a future StopDate is valid" 'creds lu activate && ! grep -q -- --activate-ulf "$tmp/lc-calls"'
echo garbage > "$ULF"
check "activate: an activation that writes a bad ULF fails with a recovery path" \
  '! creds env FAKE_NEW_ULF=junk bash "$script" activate 2>"$tmp/err" && grep -q "invalid" "$tmp/err" && grep -q "recover:.*return.*activate" "$tmp/err"'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
