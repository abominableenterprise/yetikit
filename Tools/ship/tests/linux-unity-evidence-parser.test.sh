#!/usr/bin/env bash
# Synthetic editor regressions: evidence parser.
# shellcheck disable=SC2016,SC2034 # check() evaluates assertion strings.
set -euo pipefail
# shellcheck source=Tools/ship/tests/lib/linux-unity-evidence-fixture.sh
. "$(dirname "$0")/lib/linux-unity-evidence-fixture.sh"

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
