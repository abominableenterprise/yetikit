"""Availability check for assertions that inspect Linux process environments."""
from pathlib import Path


def available(proc=Path('/proc')):
    try:
        (proc / 'self/environ').read_bytes()
        return True
    except OSError:
        return False


def require(label, proc=Path('/proc')):
    if available(proc):
        return True
    print(f'SKIP: {label}: process inspection requires readable /proc/self/environ', flush=True)
    return False
