# shellcheck shell=bash
# Fail-closed evidence helpers for linux-unity.sh test; no editor invocations.

# The runner owns these options. -quit can exit before tests; the others hide evidence.
validate_test_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -quit|-testResults|-logFile) die "test: $arg is not allowed in forwarded Unity args (the runner owns test execution, results and logs)" ;;
    esac
  done
}

# Every original failure must have explicit passing evidence, including parameterized cases.
# $1: validated retry XML, $2: newline-separated original failed fullnames.
retry_passed_all() {
  python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except (OSError, ET.ParseError, ValueError):
    sys.exit(1)
passed = {
    node.get("fullname") for node in root.iter()
    if node.tag in ("test-case", "test-suite") and node.get("result") == "Passed"
}
sys.exit(0 if set(sys.argv[2].splitlines()) <= passed else 1)
PY
}

# $1: pass label, $2: XML, $3: allow zero-total optional Gfx (1) or filtered dual-pass selection.
# Sets TEST_EXECUTED to passed + failed after validation; retries never allow empty.
# Parse XML rather than searching for a tag in garbage, comments or a nested element.
# Python's standard library is also used by the Android tooling; no third-party parser.
test_evidence() {
  local evidence
  if ! evidence="$(python3 - "$2" "${3:-0}" <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

path, allow_empty = sys.argv[1:]

def fail(reason):
    print(reason)
    sys.exit(1)

if not os.path.isfile(path):
    fail("missing result XML")
try:
    if os.path.getsize(path) == 0:
        fail("empty result XML")
    root = ET.parse(path).getroot()
except (OSError, ET.ParseError, ValueError):
    fail("unparseable result XML")
if root.tag != "test-run":
    fail("result XML has no test-run root")
counts = []
for key in ("total", "passed", "failed", "skipped"):
    value = root.get(key, "")
    if not re.fullmatch(r"[0-9]+", value):
        fail("test-run root has missing or invalid " + key)
    counts.append(int(value))
total, passed, failed, skipped = counts
if total == 0:
    if allow_empty not in ("1", "filtered") or counts != [0, 0, 0, 0]:
        fail("no executed tests (total is 0)")
elif passed == 0 and failed == 0:
    fail("no executed tests (all skipped or ignored)")
print(passed + failed)
PY
)"; then
    log "$1: invalid test evidence: ${evidence:-could not parse result XML} ($2)"
    return 1
  fi
  TEST_EXECUTED="$evidence"
  if [ "$TEST_EXECUTED" = 0 ]; then
    if [ "${3:-0}" = filtered ]; then
      local category=pure
      [ "$1" != editmode-gfx ] || category=Gfx
      log "$1: -testFilter '$TEST_FILTER' matched no $category tests; pass empty"
    else
      log "$1: no tests selected (Gfx categories); treated as empty"
    fi
  fi
}
