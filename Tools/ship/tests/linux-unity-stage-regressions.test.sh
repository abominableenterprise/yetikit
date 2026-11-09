#!/usr/bin/env bash
# #484 timing observer regressions. Shell/fake editor only; never runs Unity.
set -euo pipefail
tests="$(cd "$(dirname "$0")" && pwd)"
script="$tests/../linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
proj="$tmp/proj"; mkdir -p "$proj"
. "$tests/lib/fake-unity.sh"
printf base > "$proj/README"
git_init
# A gate, not a long sleep, lets wrapper-only TERM complete even if Bash defers
# its trap until the foreground editor returns. Observer cleanup is still due.
cat > "$UNITY_ROOT/Editor/Unity" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -logFile) logf="$2"; shift ;; -testResults) res="$2"; shift ;; esac
  shift
done
printf 'ScriptCompilation: starting\n' > "$logf"
: > "$FAKE_TMP/editor-ready"
while [ ! -e "$FAKE_TMP/editor-release" ]; do sleep 0.02; done
printf '<test-run total="1" passed="1" failed="0" skipped="0" />\n' > "$res"
EOF
chmod +x "$UNITY_ROOT/Editor/Unity"
python3 -B - "$script" "$tests/helpers" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.path.insert(0, sys.argv[2])
from proc_inspection import require

if not require('timing observer leak regressions'):
    raise SystemExit(0)

script = sys.argv[1]
root = Path(os.environ['FAKE_TMP'])
out = Path(os.environ['OUT_DIR'])
failures = []
# Reset inherited SIGINT (test-all may background this fixture), then exec Bash.
launcher = ['perl', '-e', '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; exec @ARGV; die $!', 'bash']


def check(label, condition):
    print(('ok   ' if condition else 'FAIL ') + label, flush=True)
    if not condition:
        failures.append(label)


def until(predicate, runner=None, seconds=10):
    deadline = time.monotonic() + seconds
    while not predicate():
        if runner is not None and runner.poll() is not None:
            raise AssertionError(f'runner exited early: {runner.returncode}')
        if time.monotonic() >= deadline:
            raise AssertionError('fixture readiness/cleanup timed out')
        time.sleep(.02)


def live(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False


def marked(marker):
    found = []
    for entry in Path('/proc').glob('[0-9]*'):
        try:
            if marker in (entry / 'environ').read_bytes().split(b'\0') and live(int(entry.name)):
                found.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    return found


def cleanup(runner, marker=None):
    # Kill only this isolated fixture's group and run marker, even after a
    # failing assertion. An orphan observer must not escape into the test suite.
    if marker:
        for pid in marked(marker):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        os.killpg(runner.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    runner.wait(timeout=5)


# Drive the observer's *actual EOF polls* with a sleep shim. No timing race:
# release-N is written only after poll-N proves the previous bytes were read.
# Capture the milestone line at compile-end, so a fallback close at editor exit
# cannot masquerade as recognizing the final unterminated milestone.
observer_code = r'''
. "$(dirname "$1")/test-stages.sh"
poll=0
sleep() {
  poll=$((poll + 1))
  : > "$CASE/poll-$poll"
  while [ ! -e "$CASE/release-$poll" ]; do command sleep 0.01; done
}
test_stage() {
  printf '%s %s\t%s\n' "$1" "$2" "${line:-}" >> "$CASE/events"
}
test_editor_stages "$CASE/editor.log" "$CASE/done"
'''
for name, chunks, final in [
    ('split', [b'ScriptComp', b'ilation: starting\n', b'Completed reload\n'], 'Completed reload'),
    ('unterminated', [b'ScriptCompilation: starting\n', b'Completed re', b'load'], 'Completed reload'),
]:
    case = root / name
    case.mkdir()
    logfile = case / 'editor.log'
    logfile.write_bytes(chunks[0])
    with (case / 'stderr').open('w') as err:
        runner = subprocess.Popen(launcher + ['-c', observer_code, '_', script],
                                  env=dict(os.environ, CASE=str(case)), stderr=err,
                                  start_new_session=True)
        try:
            until(lambda: (case / 'poll-1').exists(), runner)
            with logfile.open('ab') as log:
                log.write(chunks[1])
            (case / 'release-1').touch()
            until(lambda: (case / 'poll-2').exists(), runner)
            if name == 'split':
                check('split compilation milestone survives EOF between polls (before editor exit)',
                      'compile start\t' in (case / 'events').read_text())
            with logfile.open('ab') as log:
                log.write(chunks[2])
            (case / 'release-2').touch()
            until(lambda: (case / 'poll-3').exists(), runner)
            # EOF was already observed after the final bytes, before done was
            # published: an unterminated line must survive this extra poll too.
            (case / 'done').touch()
            (case / 'release-3').touch()
            check(f'{name}: observer exits successfully', runner.wait(timeout=5) == 0)
            events = (case / 'events').read_text().splitlines()
            check(f'{name}: completed milestone is consumed, not just fallback-closed',
                  f'compile end\t{final}' in events)
            check(f'{name}: timing scopes close exactly once',
                  [line.split('\t')[0] for line in events] == [
                      'editor-launch-import start', 'editor-launch-import end',
                      'compile start', 'compile end'])
        finally:
            cleanup(runner)


def start_run(label):
    (root / 'editor-ready').unlink(missing_ok=True)
    (root / 'editor-release').unlink(missing_ok=True)
    log = (root / f'{label}.log').open('w')
    runner = subprocess.Popen(launcher + [script, 'test', 'editmode'],
                              env=dict(os.environ, EDITMODE_GFX='0'), stdout=log, stderr=log,
                              start_new_session=True)
    log.close()
    return runner


def run_marker(runner):
    pid, start = (out / 'linux-unity.pid').read_text().split()
    assert int(pid) == runner.pid
    return f'LINUX_UNITY_RUN={pid}:{start}'.encode()


def observer_ready():
    stages = out / 'test-stages.log'
    return ((root / 'editor-ready').exists() and stages.exists()
            and 'stage compile start' in stages.read_text())


# A second command is refused by the shared cleanup lock or write_pidfile. It
# must not change timing output belonging to the still-running owner.
runner = start_run('owner')
marker = None
try:
    until(observer_ready, runner)
    marker = run_marker(runner)
    pidfile = (out / 'linux-unity.pid').read_bytes()
    stages = (out / 'test-stages.log').read_bytes()
    with (root / 'contender.log').open('w') as log:
        contender = subprocess.run(launcher + [script, 'test', 'editmode'],
                                   env=dict(os.environ, EDITMODE_GFX='0'),
                                   stdout=log, stderr=log, timeout=10)
    refusal = (root / 'contender.log').read_text()
    check('overlapping test is refused while the original owner remains live',
          contender.returncode != 0 and runner.poll() is None
          and (f'another run (pid {runner.pid},' in refusal
               or f'another Unity run owns {os.environ["SHM_DIR"]};' in refusal))
    check('refused test preserves the owner pidfile',
          (out / 'linux-unity.pid').read_bytes() == pidfile)
    check('refused test neither resets nor appends to the owner stage log',
          (out / 'test-stages.log').read_bytes() == stages)
    (root / 'editor-release').touch()
    check('owning test still succeeds after contention', runner.wait(timeout=15) == 0)
finally:
    cleanup(runner, marker)


# Real command/EXIT traps, not a sourced approximation. Group INT models Ctrl-C;
# wrapper-only TERM models cancellation by an enclosing harness. timeout can put
# the editor in another group, so release its gate after signalling the wrapper.
for label, sig, group in [('group-int', signal.SIGINT, True),
                          ('wrapper-term', signal.SIGTERM, False)]:
    runner = start_run(label)
    marker = None
    try:
        until(observer_ready, runner)
        marker = run_marker(runner)
        # compile-start proves the observer is running. done_file is reserved
        # with mktemp then unlinked until editor completion; it must not be
        # recreated and abandoned by cancellation cleanup.
        if group:
            os.killpg(runner.pid, sig)
        else:
            runner.send_signal(sig)
        (root / 'editor-release').touch()
        rc = runner.wait(timeout=15)
        check(f'{label}: cancellation preserves exit {128 + sig}', rc == 128 + sig)
        deadline = time.monotonic() + 2
        while marked(marker) and time.monotonic() < deadline:
            time.sleep(.02)
        check(f'{label}: no live timing observer or editor descendant remains', not marked(marker))
        check(f'{label}: observer completion files are removed', not list(out.glob('.test-stage.*')))
        check(f'{label}: command pidfile is released', not (out / 'linux-unity.pid').exists())
    finally:
        cleanup(runner, marker)

if failures:
    raise SystemExit(f'{len(failures)} failed: ' + '; '.join(failures))
print('all passed')
PY
