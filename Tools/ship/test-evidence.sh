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

# $1: pass label, $2: XML, $3: allow a zero-total optional Gfx selection (never a retry).
# Parse XML rather than searching for a tag in garbage, comments or a nested element.
# Python's standard library is also used by the Android tooling; no third-party parser.
test_evidence() {
  local reason
  if ! reason="$(python3 - "$2" "${3:-0}" <<'PY'
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
    if allow_empty == "1" and counts == [0, 0, 0, 0]:
        print("no tests selected (Gfx categories); treated as empty")
    else:
        fail("no executed tests (total is 0)")
elif passed == 0 and failed == 0:
    fail("no executed tests (all skipped or ignored)")
PY
)"; then
    log "$1: invalid test evidence: ${reason:-could not parse result XML} ($2)"
    return 1
  fi
  [ -z "$reason" ] || log "$1: $reason"
}
