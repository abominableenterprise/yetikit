"""Inspect disposable Linux fixtures isolated in their own sessions."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def available(proc=Path('/proc')):
    marker = b'SHIP_PROC_PROBE=synthetic'
    try:
        (proc / 'self/environ').read_bytes()
        # Keep a controlled, exec'd child alive until after the read. Reading
        # our own environment alone says nothing about descendant permissions.
        probe = 'import sys; print("ready", flush=True); sys.stdin.read(1)'
        with subprocess.Popen([sys.executable, '-c', probe], env={'SHIP_PROC_PROBE': 'synthetic'},
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              start_new_session=True) as child:
            if child.stdout.readline() != b'ready\n':
                return False
            return marker in (proc / str(child.pid) / 'environ').read_bytes().split(b'\0')
    except OSError:
        return False


def require(label, proc=Path('/proc')):
    if available(proc):
        return True
    print(f'SKIP: {label}: process inspection requires a readable child environment in /proc',
          flush=True)
    return False


def live_session(entry):
    try:
        # The comm field can contain spaces and parentheses. Fields after it
        # start with state, parent PID, process group and session ID.
        fields = (entry / 'stat').read_bytes().rsplit(b') ', 1)[1].split()
    except (FileNotFoundError, ProcessLookupError):
        return None
    return None if fields[0] in (b'Z', b'X') else int(fields[3])


def session_members(session, proc):
    # Unlike a parent tree, the session still identifies reparented orphans,
    # including children in another process group (e.g. GNU timeout).
    for entry in proc.iterdir():
        if entry.name.isdecimal() and live_session(entry) == session:
            yield entry


def marked(label, marker, session, proc=Path('/proc')):
    """Return known leaks, [] for a complete clean scan, or None if inconclusive."""
    found = []
    incomplete = False
    try:
        for entry in session_members(session, proc):
            try:
                environment = (entry / 'environ').read_bytes()
                if not environment:
                    raise OSError('empty fixture environment')
            except OSError:
                # A process may exit between stat and environ; only ignore
                # the error if it is no longer a live member of this session.
                if live_session(entry) == session:
                    incomplete = True
                continue
            if marker in environment.split(b'\0') and live_session(entry) == session:
                found.append(int(entry.name))
    except OSError:
        incomplete = True
    if incomplete and not found:
        print(f'SKIP: {label}: fixture environment scan is incomplete', flush=True)
        return None
    return found


def wait_marked(label, marker, session, seconds=2):
    deadline = time.monotonic() + seconds
    while True:
        remaining = marked(label, marker, session)
        if not remaining or time.monotonic() >= deadline:
            return remaining
        time.sleep(.02)


def cleanup_session(process):
    """Clean up an isolated synthetic session without relying on environments."""
    # Every caller starts a new session. This also finds orphaned workers in
    # other groups when the leak assertion had to skip unreadable environments.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        for entry in session_members(process.pid, Path('/proc')):
            try:
                os.kill(int(entry.name), signal.SIGKILL)
            except ProcessLookupError:
                pass
    except OSError:
        # On hosts without proc inspection the original group is still owned.
        pass
    process.wait(timeout=5)
