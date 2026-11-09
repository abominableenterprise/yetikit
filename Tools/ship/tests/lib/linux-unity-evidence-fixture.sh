# Shared isolated setup for the topical evidence regressions.
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "$0")/lib/fake-unity.sh"

# The fake editor exits synchronously and leaves no editor workers to settle.
# Remove only cleanup's fixed grace sleep in the temporary vendored copy;
# process inspection, shared-file safety checks and real timeouts stay intact.
python3 - "$script" "$proj" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
assert path.resolve().is_relative_to(Path(sys.argv[2]).resolve())
source = path.read_text()
needle = '  sleep 2\n  wipe_unity_shared_files\n'
assert source.count(needle) == 1
path.write_text(source.replace(needle, '  wipe_unity_shared_files\n'))
PY
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
