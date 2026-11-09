#!/usr/bin/env python3
"""Check all tracked and non-ignored Tools text, not just changed lines."""
from pathlib import Path
import re
import subprocess
import sys


def validate(root):
    listed = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'Tools/'],
        cwd=root,
    )
    errors = []
    for relative in sorted(set(filter(None, listed.split(b'\0')))):
        path = root / relative.decode('utf-8', errors='surrogateescape')
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        # Match Git's inexpensive binary-file heuristic.
        if b'\0' in data[:8000]:
            continue
        lines = data.split(b'\n') if data else []
        if data.endswith(b'\n'):
            lines.pop()
        name = str(path.relative_to(root))
        for number, line in enumerate(lines, 1):
            if re.search(rb'[ \t\r]+$', line):
                errors.append(f'{name}:{number}: trailing whitespace')
        if lines and not lines[-1].strip(b' \t\r'):
            errors.append(f'{name}:{len(lines)}: blank line at EOF')
    return errors


if __name__ == '__main__':
    failures = validate(Path(__file__).resolve().parents[2])
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        raise SystemExit(1)
    print('Tools whitespace checks passed')
