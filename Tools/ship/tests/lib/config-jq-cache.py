#!/usr/bin/env python3
"""Runner-only memoization of the pure config filters, never arbitrary queries."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

args = sys.argv[1:]
real = os.environ['SHIP_TEST_REAL_JQ']
cache = Path(os.environ['SHIP_TEST_JQ_CACHE'])
mode = ''
filter_path = input_path = None
if len(args) == 4 and args[:2] == ['-sr', '-f']:
    mode, filter_path, input_path = 'schema', args[2], args[3]
elif len(args) == 7 and args[:5] == [
    '-sr', '--argjson', 'questAbsoluteKnownFlakes', 'true', '-f'
]:
    mode, filter_path, input_path = 'quest-schema', args[5], args[6]
elif len(args) == 3 and args[0] == '-f':
    mode, filter_path, input_path = 'paths', args[1], args[2]
elif len(args) == 3 and args[:2] == ['-j', '-f']:
    mode, filter_path = 'values', args[2]

expected = {
    'schema': 'config.jq', 'quest-schema': 'config.jq',
    'paths': 'config-paths.jq', 'values': 'config-values.jq',
}
if (not mode or Path(filter_path).name != expected[mode]
        or Path(filter_path).parent.name != 'lib'):
    os.execv(real, [real, *args])
try:
    filter_bytes = Path(filter_path).read_bytes()
    source = Path(input_path).read_bytes() if input_path else sys.stdin.buffer.read()
except OSError:
    os.execv(real, [real, *args])

key = hashlib.sha256()
for part in (mode.encode(), filter_bytes, source):
    key.update(len(part).to_bytes(8, 'big'))
    key.update(part)
entry = cache / key.hexdigest()
try:
    output = entry.read_bytes()
except FileNotFoundError:
    result = subprocess.run([real, *args], input=source if not input_path else None,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    output = result.stdout
    # Failed commands and stderr-producing commands are never cached.
    # Real validation diagnostics are successful stdout values and remain data.
    if result.returncode == 0 and not result.stderr:
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as pending:
            pending.write(output)
        os.replace(pending.name, entry)
    sys.stdout.buffer.write(output)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
else:
    sys.stdout.buffer.write(output)
