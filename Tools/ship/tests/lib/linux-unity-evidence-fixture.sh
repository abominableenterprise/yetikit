# Shared isolated setup for the topical evidence regressions.
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "$0")/lib/fake-unity.sh"
run() { : > "$tmp/runs"; rc=0; bash "$script" test "$@" 2>"$tmp/err" || rc=$?; }

printf 'X.Tests.Flaky\n' > "$tmp/flakes"

evidence_filtered_invalid() {
for mode in "$@"; do
  FAKE_GFX_XML_MODE="$mode" run editmode -testFilter PureClass
  check "a filter does not excuse Gfx $mode evidence" \
    '[ "$rc" != 0 ] && grep -q "editmode-gfx:.*test evidence" "$tmp/err"'
  FAKE_XML_MODE="$mode" FAKE_GFX_XML_MODE=normal run editmode -testFilter GfxClass
  check "a filter does not excuse pure $mode evidence" \
    '[ "$rc" != 0 ] && grep -q "editmode:.*test evidence" "$tmp/err"'
done
}

evidence_implicit_invalid() {
for mode in "$@"; do
  FAKE_GFX_XML_MODE="$mode" run editmode
  check "implicit Gfx does not excuse $mode evidence" '[ "$rc" != 0 ]'
done
}
