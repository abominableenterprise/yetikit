#!/usr/bin/env python3
"""Exercise both runner entry points using disposable, gated shell fixtures."""
import argparse
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import subprocess
import tempfile
import time
import uuid

from proc_inspection import cleanup_session, live_session, require, wait_marked

# These lifecycle assertions need process state and environment enumeration.
if not require('runner lifecycle regressions'):
    raise SystemExit(0)

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


def fixture_pid(path):
    try:
        record = path.read_bytes()
    except FileNotFoundError:
        return None
    # Require the line terminator: a prefix of the PID may also be numeric.
    if re.fullmatch(rb'[1-9][0-9]*\n', record):
        return int(record)


def delayed_pid_write(case):
    path = case.state / 'delayed.pid'
    assert fixture_pid(path) is None
    # Hold the producer open across reads so the empty/partial windows are
    # guaranteed even on a loaded worker. A digit alone is not the PID.
    with path.open('w', buffering=1) as writer:
        assert fixture_pid(path) is None, 'empty PID file reported ready'
        writer.write('4')
        writer.flush()
        assert fixture_pid(path) is None, 'partial PID file reported ready'
        writer.write('242\n')
        assert fixture_pid(path) == 4242
    for invalid in ('not-a-pid\n', '0\n', '-4242\n', '4242\n5\n'):
        path.write_text(invalid)
        assert fixture_pid(path) is None, invalid


def live(pid):
    return live_session(Path(f'/proc/{pid}')) is not None


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
        for key in ('TEST_JOBS', 'SHIP_TEST_JOBS', 'TEST_FILE_TIMEOUT', 'SHIP_TEST_FILE_TIMEOUT'):
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
            self.env['SHIP_TEST_FILE_TIMEOUT' if self.kind == 'full' else 'TEST_FILE_TIMEOUT'] = str(timeout)
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
        if self.process is not None:
            cleanup_session(self.process)


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
for name in RETURN_ATTEMPTED ACTIVATION_FD EXIT_RC LINUX_UNITY_RUN; do
  if [[ -v $name ]]; then echo "inherited runner variable: $name"; exit 1; fi
done
''')
    inherited_home = case.root / 'inherited-home'
    inherited_tmp = case.root / 'inherited-tmp'
    for directory in (inherited_home, inherited_tmp):
        directory.mkdir()
        (directory / 'keep').touch()
    case.env.update(UNITY_SECRET='synthetic', THEROBOTS_TASK_TOKEN='synthetic',
                    HOME=str(inherited_home), TMPDIR=str(inherited_tmp),
                    RETURN_ATTEMPTED='1', ACTIVATION_FD='99', EXIT_RC='42', LINUX_UNITY_RUN='1')
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
    pid = None

    def stubborn_ready():
        nonlocal pid
        pid = fixture_pid(case.state / 'stubborn.pid')
        return pid is not None

    until(stubborn_ready, runner)
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
    label = f'{case.kind}: cancel-{sig.name}: no marked descendant remains'
    remaining = wait_marked(label, case.marker, runner.pid, seconds=3)
    if remaining is not None:
        assert not remaining, (label, remaining)
        print(f'ok   {label}', flush=True)


def timeout(case):
    case.fixture('0-hung', '''
trap 'echo cleaned > "$RUNNER_CASE/cleaned"' EXIT
echo $$ > "$RUNNER_CASE/fixture.pid"
timeout -k 60 300 bash -c 'trap "" TERM; echo $$ > "$RUNNER_CASE/stubborn.pid"; exec sleep 300' &
wait
''')
    case.fixture('1-next', 'echo next > "$RUNNER_CASE/next"')
    runner = case.start(jobs=1, timeout=4)
    ready = case.state / 'stubborn.pid'
    until(lambda: fixture_pid(ready) is not None, runner)
    pid = fixture_pid(ready)
    fixture = fixture_pid(case.state / 'fixture.pid')
    assert live(pid) and os.getpgid(pid) != os.getpgid(fixture), 'nested group was not exercised'
    output = case.finish(1 if case.kind == 'full' else 124)
    assert (case.state / 'next').exists(), 'timeout stopped remaining files'
    assert (case.state / 'cleaned').exists(), 'timeout skipped EXIT cleanup'
    label = f'{case.kind}: file timeout left a marked descendant'
    remaining = wait_marked(label, case.marker, runner.pid, seconds=3)
    if remaining is not None:
        assert not remaining, (label, remaining)
    until(lambda: not live(pid), seconds=3)
    expected = 'FAILED: 0-hung.test.sh (exit 124)' if case.kind == 'full' else 'timed out after 4 s'
    assert expected in output, output


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
    check('shared', 'delayed-pid-write', delayed_pid_write)
    for kind in ('full', 'shared'):
        check(kind, 'bounded-file-timeout', timeout)
