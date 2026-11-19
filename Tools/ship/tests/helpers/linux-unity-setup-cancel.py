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
printf '%s\n' "$BASHPID" > wrapper.pid
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


def eventually(predicate, description='synthetic setup worker startup'):
    deadline = time.monotonic() + 8
    while True:
        result = predicate()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise AssertionError(f'timed out waiting for {description}')
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


def move_case(root, env, leader_failure=False):
    # The test never elevates. For wrapper cancellation, fake sudo drops UID
    # and the caller lacks CAP_KILL. In both cases mv escapes the launching
    # group and ignores TERM.
    script(root / 'sudo', f'''#!{sys.executable}
import os, sys
args = sys.argv[1:]
if 'find' in args and '-exec' in args:
    if args[0] == '/usr/bin/python3':
        os.chmod(os.path.dirname(args[4]), 0o755)
    if not {leader_failure!r}:
        args = [*{AS_OTHER_UID!r}, *args]
if {leader_failure!r} and args[:2] == ['rm', '-rf'] and '.unity-extract.' in args[-1]:
    from pathlib import Path
    worker, _ = Path('move.pid').read_text().split()
    Path('cleanup-worker-state').write_text(str(Path(f'/proc/{{worker}}').exists()))
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
with open('move.starting', 'w') as out:
    print(os.getpid(), os.getppid(), file=out)
os.rename('move.starting', 'move.pid')
while True:
    time.sleep(1)
''')
    args = ['bash', '-c', DRIVER, '_', str(SHIP), 'move']
    with (root / 'log').open('w') as log:
        prefix = [] if leader_failure else WITHOUT_KILL
        wrapper = subprocess.Popen([*prefix, *args], cwd=root, env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True)
        marker = root / 'move.pid'
        eventually(marker.exists)
        worker, find = map(int, marker.read_text().split())
        assert live(worker)
        if leader_failure:
            os.kill(find, signal.SIGKILL)
            assert wrapper.wait(timeout=8) == 137
            assert (root / 'cleanup-worker-state').read_text() == 'False', (
                'stage cleanup ran before the move descendant was reaped'
            )
            assert not Path(f'/proc/{worker}').exists()
        else:
            unrelated = subprocess.Popen([*AS_OTHER_UID, '/bin/sleep', '30'])
            assert Path(f'/proc/{worker}').stat().st_uid == 65534
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


def terminal_case(root, env, interrupt_handler=False, escalate=None, signal_worker=False,
                  signal_group=False):
    directed = escalate is not None
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
if {directed!r}:
    leader, supervisor = os.getpid(), os.getppid()
    if os.fork() == 0:
        os.setsid()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        Path('package.starting').write_text(f'{{leader}} {{os.getpid()}} {{supervisor}}')
        Path('package.starting').rename('ready')
        while True:
            time.sleep(1)
else:
    Path('ready').touch()
while not Path('release').exists():
    time.sleep(0.02)
Path('write-completed').touch()
''')
    script(root / 'ldd', '#!/bin/sh\ntouch checked-libraries\n')
    driver = r'''
trap ':' TERM HUP
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
        expected = 130
        if directed:
            leader, descendant, supervisor = map(int, (root / 'ready').read_text().split())
            target = int((root / 'wrapper.pid').read_text())
            os.kill(target, signal.SIGINT)

            def interrupt_published():
                try:
                    return any(path.read_text() == '130\n' for path in root.glob('tmp.*/cancel'))
                except FileNotFoundError:
                    return False

            eventually(interrupt_published, 'wrapper to publish deferred INT')
            # Repeated INT must be ignored while the wrapper waits at the
            # barrier, not recursively enter cancellation or stop the write.
            ignored = next(line for line in Path(f'/proc/{target}/status').read_text().splitlines()
                           if line.startswith('SigIgn:'))
            assert int(ignored.split()[1], 16) & (1 << (signal.SIGINT - 1))
            os.kill(target, signal.SIGINT)
            assert live(leader) and live(descendant), 'protected write did not defer INT'
            if signal_group:
                # Freeze the polling sleep and supervisor to make the order
                # independent of scheduling: escalation must survive a failed
                # sleep while the cleanup barrier is still held.
                children = Path(f'/proc/{target}/task/{target}/children')

                def poll_sleep(previous=0, stop=False):
                    try:
                        pids = children.read_text().split()
                    except FileNotFoundError:
                        return 0
                    for child in map(int, pids):
                        if child == previous:
                            continue
                        try:
                            if Path(f'/proc/{child}/comm').read_text().strip() == 'sleep':
                                if stop:
                                    os.kill(child, signal.SIGSTOP)
                                return child
                        except (ProcessLookupError, FileNotFoundError):
                            continue
                    return 0

                sleeper = eventually(lambda: poll_sleep(stop=True), 'wrapper barrier polling sleep')
                os.kill(supervisor, signal.SIGSTOP)
                try:
                    os.killpg(os.getpgid(target), escalate)
                    try:
                        os.kill(sleeper, signal.SIGCONT)
                    except ProcessLookupError:
                        pass
                    eventually(lambda: not live(target) or poll_sleep(previous=sleeper),
                               'wrapper to resume polling after escalation')
                    assert live(target), 'wrapper exited before the cleanup barrier opened'
                finally:
                    os.kill(supervisor, signal.SIGCONT)
            else:
                os.kill(supervisor if signal_worker else target, escalate)
            if not signal_worker:
                expected = 128 + escalate
        else:
            os.write(tty, b'\x03')
            (root / 'release').touch()
        result = []

        def exited():
            pid, status = os.waitpid(wrapper, os.WNOHANG)
            if pid:
                result.append(os.waitstatus_to_exitcode(status))
            return pid

        eventually(exited, 'package cancellation to return')
        if directed:
            assert not (root / 'write-completed').exists()
            assert not any(Path(f'/proc/{pid}').exists() for pid in (leader, descendant)), (
                'package processes were not reaped before cancellation returned'
            )
        else:
            assert (root / 'write-completed').exists(), 'Ctrl-C interrupted the package write'
        assert result == [expected], f'expected cancellation status {expected}, got {result}'
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
        'move-leader-failure': lambda root, env: move_case(root, env, leader_failure=True),
        'terminal': terminal_case,
        'terminal-handler': lambda root, env: terminal_case(root, env, interrupt_handler=True),
        'wrapper-int-term': lambda root, env: terminal_case(root, env, True, signal.SIGTERM),
        'wrapper-int-hup': lambda root, env: terminal_case(root, env, True, signal.SIGHUP),
        'wrapper-int-worker-term': lambda root, env: terminal_case(root, env, True, signal.SIGTERM, True),
        'wrapper-int-group-term': lambda root, env: terminal_case(root, env, True, signal.SIGTERM, signal_group=True),
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
            env = {'PATH': f'{root}:{os.defpath}', 'HOME': tmp, 'TMPDIR': tmp, 'LC_ALL': 'C'}
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
