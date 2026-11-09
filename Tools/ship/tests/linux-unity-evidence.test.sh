#!/usr/bin/env bash
# Fail-closed test evidence, using only the synthetic editor.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
proj="$tmp/proj"
. "$(dirname "$0")/lib/fake-unity.sh"
run() { : > "$tmp/runs"; rc=0; bash "$script" test "$@" 2>"$tmp/err" || rc=$?; }

for platform in editmode playmode; do
  FAKE_XML_MODE=no-file EDITMODE_GFX=0 run "$platform"
  check "$platform: exit 0 without XML fails, naming the pass and missing XML" \
    '[ "$rc" != 0 ] && grep -q "$platform:.*missing.*XML" "$tmp/err"'
done
for mode in empty garbage zero skipped; do
  FAKE_XML_MODE="$mode" EDITMODE_GFX=0 run editmode
  check "pure pass: $mode evidence fails with a reason" \
    '[ "$rc" != 0 ] && grep -q "editmode:.*test evidence" "$tmp/err"'
done
for platform in editmode playmode pr; do
  for arg in -quit -testResults -logFile; do
    extra=("$arg"); [ "$arg" = -quit ] || extra+=(x)
    run "$platform" "${extra[@]}"
    check "$platform: $arg rejected before any editor starts" \
      '[ "$rc" != 0 ] && [ ! -s "$tmp/runs" ] && grep -q -- "error:.*$arg.*not allowed" "$tmp/err"'
  done
done
printf 'X.Tests.Flaky\n' > "$tmp/flakes"
for mode in no-file empty garbage zero skipped; do
  FAKE_FAILS=X.Tests.Flaky KNOWN_FLAKES="$tmp/flakes" FAKE_RETRY_XML_MODE="$mode" EDITMODE_GFX=0 run editmode
  check "retry with $mode evidence cannot turn the original failure green" \
    '[ "$rc" = 2 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && ! grep -q flaky-passed "$tmp/err" && grep -q "editmode-retry:.*test evidence" "$tmp/err"'
done
FAKE_GFX_XML_MODE=zero run editmode
check "plain EditMode allows an implicit empty Gfx pass and explains why" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx: no tests selected (Gfx categories); treated as empty" "$tmp/err"'
FAKE_GFX_XML_MODE=zero run editmode -testFilter PureClass
check "filtered pure tests allow an empty Gfx pass with an explanation" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx: -testFilter.*PureClass.*no Gfx tests; pass empty" "$tmp/err"'
FAKE_XML_MODE=zero FAKE_GFX_XML_MODE=normal run editmode -testFilter GfxClass
check "filtered Gfx tests allow an empty pure pass with an explanation" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode: -testFilter.*GfxClass.*no pure tests; pass empty" "$tmp/err"'
FAKE_XML_MODE=zero run editmode -testFilter Nope
check "a filter matching neither pass fails closed and names the filter" \
  '[ "$rc" != 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q -- "-testFilter.*Nope.*no executed tests across.*passes" "$tmp/err"'
for mode in no-file empty garbage skipped; do
  FAKE_GFX_XML_MODE="$mode" run editmode -testFilter PureClass
  check "a filter does not excuse Gfx $mode evidence" \
    '[ "$rc" != 0 ] && grep -q "editmode-gfx:.*test evidence" "$tmp/err"'
  FAKE_XML_MODE="$mode" FAKE_GFX_XML_MODE=normal run editmode -testFilter GfxClass
  check "a filter does not excuse pure $mode evidence" \
    '[ "$rc" != 0 ] && grep -q "editmode:.*test evidence" "$tmp/err"'
done
FAKE_XML_MODE=zero run editmode
check "unfiltered pure pass still cannot be empty" '[ "$rc" != 0 ]'
EDITMODE_GFX=0 run editmode -testFilter PureClass
check "disabling Gfx still runs just the filtered pure pass" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 1 ]'
FAKE_XML_MODE=zero EDITMODE_GFX=0 run editmode -testFilter PureClass
check "disabling Gfx still requires executed pure tests" '[ "$rc" != 0 ]'
FAKE_FAILS=X.Tests.Flaky KNOWN_FLAKES="$tmp/flakes" FAKE_RETRY_XML_MODE=zero run editmode -testFilter PureClass
check "filtered dual-pass retries must still execute tests" \
  '[ "$rc" = 2 ] && grep -q "editmode-retry:.*test evidence" "$tmp/err"'
FAKE_UNITY_RC=7 FAKE_GFX_XML_MODE=zero run editmode -testFilter PureClass
check "an empty filtered pass does not excuse an editor failure" '[ "$rc" = 7 ]'
FAKE_GFX_XML_MODE=zero run editmode -testCategory Gfx
check "an explicit Gfx category must execute tests" '[ "$rc" != 0 ]'
for mode in no-file empty garbage skipped; do
  FAKE_GFX_XML_MODE="$mode" run editmode
  check "implicit Gfx does not excuse $mode evidence" '[ "$rc" != 0 ]'
done
FAKE_XML_MODE=zero run playmode
check "PlayMode must execute tests" '[ "$rc" != 0 ]'
FAKE_FAILS=X.Tests.Broken EDITMODE_GFX=0 run editmode
check "a real test failure retains editor exit 2" '[ "$rc" = 2 ]'
run editmode
check "normal EditMode still passes with both XML totals" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode.xml:.*total=\"1\"" "$tmp/err" && grep -q "editmode-gfx.xml:.*passed=\"1\"" "$tmp/err"'
run playmode
check "normal PlayMode still passes" '[ "$rc" = 0 ]'

# A changed Gfx fixture makes test pr actually invoke its optional Gfx pass.
mkdir -p "$proj/Assets/Tests/EditMode"
fixture="$proj/Assets/Tests/EditMode/GraphicsTests.cs"
printf 'namespace X.Tests {\n[Category("Gfx")]\npublic class GraphicsTests { }\n}\n' > "$fixture"
git_init
printf '// changed\n' >> "$fixture"
FAKE_GFX_XML_MODE=zero run pr
check "PR Gfx may select zero tests with the same explanation" \
  '[ "$rc" = 0 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx: no tests selected (Gfx categories); treated as empty" "$tmp/err"'
FAKE_XML_MODE=zero EDITMODE_GFX=0 run pr
check "PR pure pass may not select zero tests" '[ "$rc" != 0 ]'

for platform in editmode pr; do
  FAKE_FAILS=X.Tests.Broken FAKE_GFX_XML_MODE=no-file run "$platform"
  check "$platform: a later evidence-only failure preserves editor exit 2" \
    '[ "$rc" = 2 ] && [ "$(wc -l < "$tmp/runs")" = 2 ] && grep -q "editmode-gfx:.*missing.*XML" "$tmp/err"'
done

# Parser boundaries: only a well-formed test-run root with all four counts is evidence.
. "$(dirname "$script")/test-evidence.sh"
log() { printf '%s\n' "$*" >> "$tmp/parser.log"; }
for xml in \
  '<other total="1" passed="1" failed="0" skipped="0" />' \
  '<other><test-run total="1" passed="1" failed="0" skipped="0" /></other>' \
  '<!-- <test-run total="1" passed="1" failed="0" skipped="0" /> -->' \
  '<test-run total="1" passed="1" failed="0" />' \
  '<test-run total="-1" passed="1" failed="0" skipped="0" />' \
  '<test-run total="x" passed="1" failed="0" skipped="0" />' \
  '<test-run total="1" passed="1" failed="0" skipped="0">'; do
  printf '%s\n' "$xml" > "$tmp/parser.xml"
  rc=0; test_evidence parser "$tmp/parser.xml" 0 || rc=$?
  check "malformed root/counts rejected: $xml" '[ "$rc" != 0 ]'
done
printf "<?xml version='1.0'?>\n<test-run skipped='0'\n failed='0' passed='01' total='01' />\n" > "$tmp/parser.xml"
rc=0; test_evidence parser "$tmp/parser.xml" 0 || rc=$?
check "valid multiline root, reordered attributes and single quotes accepted" '[ "$rc" = 0 ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
