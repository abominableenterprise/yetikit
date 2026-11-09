#!/usr/bin/env python3
"""Exercise both runner entry points using disposable, gated shell fixtures."""
import argparse
import os
from pathlib import Path
import shutil
import shlex
import signal
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ship-dir', type=Path, default=Path(__file__).resolve().parents[2],
                    help='runner source directory (also accepts a baseline copy)')
parser.add_argument('--kind', choices=('full', 'shared'))
parser.add_argument('--case', help='run only the named regression')
ARGS = parser.parse_args()
SHIP = ARGS.ship_dir.resolve()
LAUNCHER = ['perl', '-e', '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; exec @ARGV; die $!', 'bash']


def until(predicate, runner=None, seconds=15):
    deadline = time.monotonic() + seconds
    while not predicate():
        if runner is not None:
            assert runner.poll() is None, 'runner exited before fixture readiness'
        assert time.monotonic() < deadline, 'fixture deadline exceeded'
        time.sleep(.02)


def live(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False


def marked(marker):
    result = []
    for path in Path('/proc').glob('[0-9]*/environ'):
        try:
            if marker in path.read_bytes().split(b'\0') and live(int(path.parent.name)):
                result.append(int(path.parent.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    return result


class Case:
    def __init__(self, root, kind, label):
        self.root = root / f'{kind}-{label}'
        self.tests = self.root / 'Tools/ship/tests'
        self.tests.mkdir(parents=True)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.kind = kind
        self.runner = self.tests / 'run.sh' if kind == 'full' else self.tests.parent / 'test-all.sh'
        shutil.copy2(SHIP / ('tests/run.sh' if kind == 'full' else 'test-all.sh'), self.runner)
        (self.tests / 'lib').mkdir()
        shutil.copy2(SHIP / 'tests/lib/config-jq-cache.py', self.tests / 'lib/config-jq-cache.py')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # Deliberately differ from the host's getconf count: nproc is authoritative.
        self.command('nproc', 'echo 4\n')
        # A full runner may itself be driving this regression. Do not chain its
        # jq shim back into itself when the nested runner replaces cache env.
        real_jq = os.environ.get('SHIP_TEST_ORIGINAL_JQ', shutil.which('jq'))
        if real_jq:
            self.command('jq', f'exec {shlex.quote(real_jq)} "$@"\n')
        self.marker = f'RUNNER_REGRESSION_MARKER={uuid.uuid4()}'.encode()
        self.env = dict(os.environ, RUNNER_CASE=str(self.state),
                        RUNNER_REGRESSION_MARKER=self.marker.decode().split('=', 1)[1],
                        PATH=f'{self.bin}:{os.environ["PATH"]}')
        for key in ('TEST_JOBS', 'SHIP_TEST_JOBS', 'TEST_FILE_TIMEOUT'):
            self.env.pop(key, None)
        self.log = self.root / 'output'
        self.process = None

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)

    def fixture(self, name, body, serial=False):
        (self.tests / f'{name}.test.sh').write_text(
            '#!/usr/bin/env bash\n' + ('# test-all: serial\n' if serial else '')
            + 'set -euo pipefail\n' + body + '\n')

    def start(self, jobs=None, timeout=None):
        if jobs is not None:
            self.env['SHIP_TEST_JOBS' if self.kind == 'full' else 'TEST_JOBS'] = str(jobs)
        if timeout is not None:
            self.env['TEST_FILE_TIMEOUT'] = str(timeout)
        with self.log.open('w') as log:
            self.process = subprocess.Popen(LAUNCHER + [str(self.runner)]
                                            + ([] if self.kind == 'full' else ['--all']),
                                            env=self.env, stdout=log, stderr=log,
                                            start_new_session=True)
        return self.process

    def finish(self, expected=0):
        status = self.process.wait(timeout=20)
        output = self.log.read_text()
        assert status == expected, (status, expected, output)
        return output

    def cleanup(self):
        # The regression must not leak a stubborn process even when it fails.
        for pid in marked(self.marker):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)


GATE = '''
: > "$RUNNER_CASE/ready-NAME"
while [ ! -e "$RUNNER_CASE/release-NAME" ]; do sleep 0.02; done
'''


def check(kind, label, callback):
    if (ARGS.kind and ARGS.kind != kind) or (ARGS.case and ARGS.case != label):
        return
    case = Case(ROOT, kind, label)
    try:
        callback(case)
        print(f'ok   {kind}: {label}', flush=True)
    except Exception:
        if case.log.exists():
            print(case.log.read_text(), flush=True)
        raise
    finally:
        case.cleanup()


def defaults(case):
    for i in range(5):
        case.fixture(f'{i}-gate', GATE.replace('NAME', str(i)))
    runner = case.start()
    until(lambda: all((case.state / f'ready-{i}').exists() for i in range(4)), runner)
    # Four occupied slots must prevent the fifth fixture from starting.
    time.sleep(.3)
    assert not (case.state / 'ready-4').exists(), 'CPU bound exceeded'
    (case.state / 'release-1').touch()
    until(lambda: (case.state / 'ready-4').exists(), runner)
    assert not (case.state / 'release-0').exists(), 'did not refill a completed slot'
    for i in range(5):
        (case.state / f'release-{i}').touch()
    output = case.finish()
    assert 'slowest 5 files (seconds):' in output.lower()
    summary = output.lower().split('slowest 5 files (seconds):', 1)[1]
    assert sum('-gate.test.sh' in line for line in summary.splitlines()) == 5, output


def scheduling(case):
    # The first fixture cannot finish until the third starts. A fixed batch or
    # a wait on the first PID instead of any completed PID deadlocks this gate.
    case.fixture('0-long', 'echo long-begin\n' + GATE.replace('NAME', 'long') + '\necho long-end')
    case.fixture('1-quick', 'echo quick-begin; echo quick-end >&2')
    case.fixture('2-refill', ': > "$RUNNER_CASE/release-long"\necho refill')
    case.start(jobs=2)
    output = case.finish()
    assert output.index('quick-end') < output.index('long-begin'), output
    lines = output.splitlines()
    assert lines.index('long-end') == lines.index('long-begin') + 1, output
    assert 'elapsed:' in output.lower(), output


def isolation(case):
    for i in range(2):
        case.fixture(f'{i}-isolated', '''
for directory in "$HOME" "$TMPDIR" "$SHM_DIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"; do
  [ -d "$directory" ]; [ ! -e "$directory/owned" ]; : > "$directory/owned"
done
printf '%s\\n' "$HOME" "$TMPDIR" "$SHM_DIR" "$XDG_STATE_HOME" > "$RUNNER_CASE/paths-''' + str(i) + '''"
[ -z "${UNITY_SECRET+x}" ]; [ -z "${THEROBOTS_TASK_TOKEN+x}" ]
''')
    inherited_home = case.root / 'inherited-home'
    inherited_tmp = case.root / 'inherited-tmp'
    for directory in (inherited_home, inherited_tmp):
        directory.mkdir()
        (directory / 'keep').touch()
    case.env.update(UNITY_SECRET='synthetic', THEROBOTS_TASK_TOKEN='synthetic',
                    HOME=str(inherited_home), TMPDIR=str(inherited_tmp))
    case.start(jobs=2)
    case.finish()
    paths = [(case.state / f'paths-{i}').read_text().splitlines() for i in range(2)]
    assert not set(paths[0]) & set(paths[1]), paths
    assert all(not Path(path).exists() for group in paths for path in group), paths
    assert (inherited_home / 'keep').exists(), 'removed inherited HOME'
    assert (inherited_tmp / 'keep').exists(), 'removed inherited TMPDIR'
    assert not list(inherited_tmp.glob('tmp.*')), 'owned runner sandbox leaked'


def serial_failure(case):
    # Sort serial first to prove that jobs=1 also partitions before launching.
    case.fixture('0-serial', '''
[ -e "$RUNNER_CASE/parallel-done" ]
echo serial >> "$RUNNER_CASE/order"
''', serial=True)
    case.fixture('1-fail', 'echo fail >> "$RUNNER_CASE/order"; exit 7')
    case.fixture('2-parallel', 'echo parallel >> "$RUNNER_CASE/order"; : > "$RUNNER_CASE/parallel-done"')
    case.start(jobs=1)
    output = case.finish(1 if case.kind == 'full' else 7)
    assert (case.state / 'order').read_text().splitlines() == ['fail', 'parallel', 'serial']
    assert '1-fail.test.sh (exit 7)' in output, output
    assert ('2 test scripts passed; 1 failed' if case.kind == 'full' else 'ok 2 files; FAIL 1 files') in output


def cancellation(case, sig):
    case.fixture('stubborn', '''
trap 'echo cleaned > "$RUNNER_CASE/cleaned"' EXIT
timeout -k 60 300 bash -c '
  trap "" TERM
  echo $$ > "$RUNNER_CASE/stubborn.pid"
  while :; do sleep 1; done
' &
wait
''')
    runner = case.start(jobs=1)
    until(lambda: (case.state / 'stubborn.pid').exists(), runner)
    pid = int((case.state / 'stubborn.pid').read_text())
    assert live(pid)
    started = time.monotonic()
    if sig == signal.SIGINT:
        os.killpg(runner.pid, sig)
    else:
        runner.send_signal(sig)
    case.finish(128 + sig)
    assert time.monotonic() - started < 15, 'unbounded cancellation'
    until(lambda: not live(pid), seconds=3)
    assert (case.state / 'cleaned').exists(), 'fixture EXIT cleanup skipped'
    until(lambda: not marked(case.marker), seconds=3)


def timeout(case):
    case.fixture('0-hung', '''
trap 'echo cleaned > "$RUNNER_CASE/cleaned"' EXIT
bash -c 'trap "" TERM; echo $$ > "$RUNNER_CASE/stubborn.pid"; exec sleep 300' &
wait
''')
    case.fixture('1-next', 'echo next > "$RUNNER_CASE/next"')
    case.start(jobs=1, timeout=1)
    output = case.finish(124)
    assert 'timed out after 1 s' in output, output
    assert (case.state / 'next').exists(), 'timeout stopped remaining files'
    assert (case.state / 'cleaned').exists(), 'timeout skipped EXIT cleanup'
    assert not live(int((case.state / 'stubborn.pid').read_text()))


with tempfile.TemporaryDirectory(prefix='runner-regressions-') as directory:
    ROOT = Path(directory)
    for kind in ('full', 'shared'):
        for label, callback in [('cpu-default-and-bounds', defaults),
                                ('dynamic-grouped-output', scheduling),
                                ('isolated-state', isolation),
                                ('serial-after-batch-and-failure', serial_failure)]:
            check(kind, label, callback)
        for sig in (signal.SIGTERM, signal.SIGINT):
            check(kind, f'cancel-{sig.name}', lambda case, sig=sig: cancellation(case, sig))
    check('shared', 'bounded-file-timeout', timeout)
