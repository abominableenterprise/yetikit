#!/usr/bin/env bash
# Missing process inspection is reported rather than a vacuous leak-check pass.
set -euo pipefail
python3 -B - "$(dirname "$0")/helpers" <<'PY'
import contextlib
import io
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
from proc_inspection import available, require

with tempfile.TemporaryDirectory() as directory:
    proc = Path(directory) / 'missing-proc'
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert not require('planted leak assertion', proc)
    assert 'SKIP: planted leak assertion' in output.getvalue()
    assert '/proc/self/environ' in output.getvalue()
    (proc / 'self').mkdir(parents=True)
    (proc / 'self/environ').write_bytes(b'SYNTHETIC=1\0')
    assert available(proc)
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert require('available assertion', proc)
    assert not output.getvalue()
print('ok   explicit process-inspection availability and skip diagnostic')
PY
