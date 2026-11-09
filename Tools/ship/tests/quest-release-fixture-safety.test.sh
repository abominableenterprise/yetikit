#!/usr/bin/env bash
# Synthetic fixture lifecycle regressions; no editor/device or nested test suite.
# Baseline: QR_FIXTURE_TEST_LIB=/tmp/ship-fixture-before/tests/lib bash "$0"
set -euo pipefail
export QR_FIXTURE_REAL_SHIP="$(cd "$(dirname "$0")/.." && pwd)"
export QR_FIXTURE_TEST_LIB="${QR_FIXTURE_TEST_LIB:-$QR_FIXTURE_REAL_SHIP/tests/lib}"
python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

lib = Path(os.environ['QR_FIXTURE_TEST_LIB'])

def owned(marker):
    result = []
    for entry in Path('/proc').glob('[0-9]*/environ'):
        try:
            if marker.encode() in entry.read_bytes().split(b'\0'):
                result.append(int(entry.parent.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    return result

def run(label, body, expected):
    marker = 'QR_FIXTURE_SAFETY_MARKER=' + str(uuid.uuid4())
    with tempfile.TemporaryDirectory() as directory:
        env = dict(os.environ, QR_FIXTURE_SAFETY_MARKER=marker.split('=', 1)[1],
                   QR_FIXTURE_CASE=directory)
        with open(Path(directory) / 'output', 'w+') as log:
            process = subprocess.Popen(['bash', '-c', '''
set -u
. "$QR_FIXTURE_REAL_SHIP/quest-release.sh"
. "$QR_FIXTURE_TEST_LIB/quest-release-timebox.sh"
tmp="$QR_FIXTURE_CASE"
''' + body, str(lib.parent / 'synthetic.test.sh')], env=env,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                rc = process.wait(timeout=15)
                log.seek(0)
                assert rc == expected, (label, rc, log.read())
                deadline = time.monotonic() + 2
                while owned(marker) and time.monotonic() < deadline:
                    time.sleep(.02)
                assert not owned(marker), (label, 'leaked owned processes', owned(marker))
                print('ok  ', label, flush=True)
            finally:
                # A failing-first run must not itself leak the baseline's sleep.
                for pid in owned(marker):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.wait(timeout=5)

failures = []
for label, body, expected in [
    ('gate watchdog timeout reaps its marked sleep', 'qr_test_watchdog_timeout', 0),
    ('gate watchdog cleanup reaps every marked sleep', 'qr_test_watchdog_cleanup', 0),
    ('TERM between sleep fork and PID assignment reaps sleep', r'''
qr_test_no_gtimeout
set -T
trap 'if [ "$BASH_COMMAND" = '\''child=$!'\'' ]; then kill -TERM "$$"; fi' DEBUG
qr_test_block_until_term "$tmp/startup"
''', 143),
    ('failed readiness exits with no owned blocker', '''
QR_FIXTURE_MANAGE_CHILDREN=1 QR_FIXTURE_OWNED_PIDS=''
trap 'if declare -F qr_fixture_cleanup_children >/dev/null; then qr_fixture_cleanup_children; fi' EXIT
qr_test_no_gtimeout
qr_test_block_until_term "$tmp/blocker" >/dev/null 2>&1 & owner=$!
while [ ! -f "$tmp/blocker.started" ]; do builtin command sleep .02; done
# Force readiness failure without a 60-second delay; owner is still alive.
kill() { if [ "${1:-}" = -0 ]; then return 1; fi; builtin kill "$@"; }
qr_fixture_wait_ready "$tmp/never-ready" "$owner" && exit 1
exit 0
''', 0),
    ('independent config fixtures have distinct serials', '''
. "$QR_FIXTURE_TEST_LIB/quest-release-config.sh"
qr_test_config "$tmp/first/config"; first="$QUEST_SERIAL"
qr_test_config "$tmp/second/config"
[ "$first" != "$QUEST_SERIAL" ]
''', 0),
]:
    try:
        run(label, body, expected)
    except Exception as error:
        failures.append(str(error))
for failure in failures:
    print('FAIL', failure)
raise SystemExit(bool(failures))
PY
