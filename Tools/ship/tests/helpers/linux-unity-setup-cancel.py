"""Exercise the setup installer with a synthetic non-PTY sudo and a real Ctrl-C."""

import ctypes
import errno
import os
from pathlib import Path
import pty
import signal
import subprocess
import sys
import tempfile
import time


SHIP = Path(__file__).resolve().parents[2]
AS_OTHER_UID = ('setpriv', '--reuid=65534', '--regid=65534', '--clear-groups', '--')
WITHOUT_KILL = ('setpriv', '--bounding-set=-kill', '--')

DRIVER = r'''
set -euo pipefail
. "$1/lib/linux-unity-supervise.sh"
. "$1/linux-unity-setup.sh"
SHIP_TOOL_DIR="$1"
as_root() { sudo "$@"; }
eval "$(awk '/^descendants\(\) \{/{show=1} show{print} show && /^}/{exit}' "$1/linux-unity.sh")"
log() { echo "$*"; }
die() { echo "$*" >&2; exit 1; }
chain_exit_trap() { trap "$1" EXIT; }
UNITY_ROOT="$PWD/editor"
BIN_REL=Unity LC_REL=Client UNITY_VERSION=fixture UNITY_IMAGE=fixture
UNITY_BIN="$UNITY_ROOT/$BIN_REL" LC="$UNITY_ROOT/$LC_REL"
if [ "$2" = move ]; then install_editor; else install_libs; fi
: > next-step
'''


def script(path, text):
    path.write_text(text)
    path.chmod(0o755)


def live(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1][0] != 'Z'
    except FileNotFoundError:
        return False


def eventually(predicate):
    deadline = time.monotonic() + 8
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('timed out waiting for synthetic setup worker')
        time.sleep(0.02)


def clean_children():
    own = os.getpid()
    descendants = Path(f'/proc/{own}/task/{own}/children')
    while True:
        for pid in descendants.read_text().split():
            try:
                os.kill(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            if os.waitpid(-1, os.WNOHANG)[0] == 0:
                time.sleep(0.02)
        except ChildProcessError:
            return


def move_case(root, env):
    # The test never elevates: fake sudo drops to a different UID, and the
    # caller lacks CAP_KILL. The grandchild escapes the launching group and
    # ignores TERM. The fixture process retains CAP_KILL solely for teardown.
    script(root / 'sudo', f'''#!{sys.executable}
import os, sys
args = sys.argv[1:]
if 'find' in args and '-exec' in args:
    if args[0] == '/usr/bin/python3':
        os.chmod(os.path.dirname(args[4]), 0o755)
    args = [*{AS_OTHER_UID!r}, *args]
os.execvp(args[0], args)
''')
    image = root / 'opt/unity'
    image.mkdir(parents=True)
    for name in ('Unity', 'Client'):
        script(image / name, '#!/bin/sh\n# fixture\n')
    script(root / 'crane', '#!/bin/sh\nexec tar -c opt/unity\n')
    script(root / 'mv', f'''#!{sys.executable}
import os, signal, time
os.setsid()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open('move.pid', 'w') as out:
    print(os.getpid(), file=out)
while True:
    time.sleep(1)
''')
    args = ['bash', '-c', DRIVER, '_', str(SHIP), 'move']
    with (root / 'log').open('w') as log:
        unrelated = subprocess.Popen([*AS_OTHER_UID, '/bin/sleep', '30'])
        wrapper = subprocess.Popen([*WITHOUT_KILL, *args], cwd=root, env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True)
        marker = root / 'move.pid'
        eventually(lambda: marker.exists() and marker.stat().st_size)
        worker = int(marker.read_text())
        assert live(worker) and Path(f'/proc/{worker}').stat().st_uid == 65534
        probe = subprocess.run([*WITHOUT_KILL, '/bin/kill', '-0', str(worker)],
                               capture_output=True, env=env)
        assert probe.returncode and os.strerror(errno.EPERM) in probe.stderr.decode()
        wrapper.terminate()
        assert wrapper.wait(timeout=8) == 143
        assert not live(worker), 'cross-UID move worker survived wrapper cancellation'
        assert unrelated.poll() is None, 'cancellation killed an unrelated process'
        assert (root / 'editor/.install-partial').exists()
        assert not (root / 'editor/.install-complete').exists()
        assert not list(root.glob('.unity-extract.*'))
        assert not (root / 'next-step').exists()
        retry = subprocess.run(args, cwd=root, env=env, capture_output=True, timeout=8)
        assert retry.returncode and b'exists but is incomplete' in retry.stderr


def terminal_case(root, env, interrupt_handler=False):
    script(root / 'sudo', '#!/bin/sh\nexec "$@"\n')
    # dpkg -s returns zero even when a known package is not configured.
    script(root / 'dpkg', '#!/bin/sh\necho "Status: install ok unpacked"\n')
    script(root / 'dpkg-query', '#!/bin/sh\necho "install ok unpacked"\n')
    script(root / 'apt-get', f'''#!{sys.executable}
import os, signal, sys, time
from pathlib import Path
if 'update' in sys.argv:
    sys.exit(0)
signal.signal(signal.SIGINT, signal.SIG_IGN)
with open('/dev/tty') as tty:
    # Either the original worker or its supervisor holds terminal control.
    with open(f'/proc/{{os.getppid()}}/stat') as parent:
        group = int(parent.read().rsplit(') ', 1)[1].split()[2])
    assert os.tcgetpgrp(tty.fileno()) in (os.getpgrp(), group)
# Package commands can install their own SIGINT handler, overriding inheritance.
if {interrupt_handler!r}:
    signal.signal(signal.SIGINT, lambda *_: sys.exit(97))
Path('ready').touch()
while not Path('release').exists():
    time.sleep(0.02)
Path('write-completed').touch()
''')
    script(root / 'ldd', '#!/bin/sh\ntouch checked-libraries\n')
    driver = r'''
rc=0; bash -c "$1" _ "$2" packages || rc=$?
python3 -c 'import os; assert os.tcgetpgrp(os.open("/dev/tty", os.O_RDONLY)) == os.getpgrp()' || exit 99
exit "$rc"
'''
    wrapper, tty = pty.fork()
    if wrapper == 0:
        os.chdir(root)
        os.execvpe('bash', ['bash', '-c', driver, '_', DRIVER, str(SHIP)], env)
    try:
        eventually((root / 'ready').exists)
        os.write(tty, b'\x03')
        (root / 'release').touch()
        result = []

        def exited():
            pid, status = os.waitpid(wrapper, os.WNOHANG)
            if pid:
                result.append(os.waitstatus_to_exitcode(status))
            return pid

        eventually(exited)
        assert (root / 'write-completed').exists(), 'Ctrl-C interrupted the package write'
        assert result == [130], f'expected cancellation after package write, got {result}'
        assert not (root / 'checked-libraries').exists()
        assert not (root / 'next-step').exists()
    finally:
        os.close(tty)


def cancelled(signum, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise SystemExit(128 + signum)


def main():
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')
    cases = {
        'move': move_case,
        'terminal': terminal_case,
        'terminal-handler': lambda root, env: terminal_case(root, env, interrupt_handler=True),
    }
    failed = False
    for name in sys.argv[1:] or cases:
        if name == 'move' and os.geteuid() != 0:
            print('skip cross-UID move: fixture needs a root runner to drop UIDs; never invokes sudo')
            continue
        # The suite's per-fixture TMPDIR is private to the launching UID.
        # This disposable sandbox must also be reachable after dropping UID.
        with tempfile.TemporaryDirectory(prefix='ship-setup-cancel-', dir='/tmp') as tmp:
            root = Path(tmp)
            if name == 'move':
                root.chmod(0o1777)  # Permit only the synthetic worker's readiness record.
            env = {'PATH': f'{root}:{os.defpath}', 'HOME': tmp, 'LC_ALL': 'C'}
            try:
                cases[name](root, env)
                print(f'ok   setup cancellation ({name})')
            except AssertionError as error:
                print(f'FAIL setup cancellation ({name}): {error}')
                if (root / 'log').exists():
                    print((root / 'log').read_text())
                failed = True
            finally:
                clean_children()
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
