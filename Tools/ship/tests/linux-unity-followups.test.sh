#!/usr/bin/env bash
# #429 lock identity, interruptible waits and handler restoration. Stubs only.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="${FOLLOWUPS_TEST_SCRIPT:-$repo/Tools/ship/linux-unity.sh}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
proj="$tmp/proj"; mkdir -p "$proj/Packages" "$proj/ProjectSettings"
printf '{}\n' > "$proj/Packages/manifest.json"
printf '{}\n' > "$proj/Packages/packages-lock.json"
echo 'm_EditorVersion: 6000.6.6f1' > "$proj/ProjectSettings/ProjectVersion.txt"
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
git_init
lc="$UNITY_ROOT/Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client"
mkdir -p "$(dirname "$lc")"
printf '#!/bin/sh\necho called >> "$FAKE_TMP/licensing-calls"\nexit 0\n' > "$lc"; chmod +x "$lc"
# Observe real contention before asking the wrapper to cancel.
cat > "$tmp/bin/flock" <<'EOF'
#!/bin/bash
if [ "$1" = -x ] && [ "${!#}" != 9 ]; then
  if [ "${FAKE_FLOCK_ERROR:-0}" = 1 ]; then
    echo failed >> "$FAKE_TMP/flock-errors"
    exit 71
  fi
  /usr/bin/flock -n "${!#}" && exit 0
  : > "$FAKE_TMP/contended"
fi
exec /usr/bin/flock "$@"
EOF
chmod +x "$tmp/bin/flock"
python3 - "$script" <<'PY'
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ['FAKE_TMP'])
ulf = Path(os.environ['ULF'])
script = sys.argv[1]
# nohup makes HUP ignored, just as asynchronous shells can ignore INT/QUIT.
# Bash cannot trap signals ignored on entry: reset them BEFORE Bash starts.
launcher = ['perl', '-e',
            '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; $SIG{HUP}="DEFAULT"; exec @ARGV; die $!',
            'bash']

# These are synchronization/cleanup checks, not four-second latency contracts.
# Bash can defer a signal until the current one-second flock attempt returns;
# startup, scheduling delays and EXIT cleanup also consume the old 4 s budget.
# Synchronize on contention/return markers and allow bounded scheduling headroom.
READINESS_TIMEOUT_SECONDS = 60
COMPLETION_TIMEOUT_SECONDS = 30
LOCK_BLOCKED_OBSERVATION_SECONDS = .2

def diagnostic(stage, started, bound):
    return (f'{stage}: elapsed {time.monotonic() - started:.2f} s '
            f'(bound {bound} s)\n' + (root / 'followups.log').read_text())

def until(condition, runner, stage):
    started = time.monotonic()
    while not condition():
        assert runner.poll() is None, diagnostic(stage + ' exited early', started,
                                                 READINESS_TIMEOUT_SECONDS)
        assert time.monotonic() - started < READINESS_TIMEOUT_SECONDS, diagnostic(
            stage + ' timed out', started, READINESS_TIMEOUT_SECONDS)
        time.sleep(.02)
    print(f'info {stage}: ready after {time.monotonic() - started:.2f} s', flush=True)

def ready(path, runner):
    until(path.exists, runner, f'waiting for {path.name}')

def completed(runner, expected, stage):
    started = time.monotonic()
    try:
        status = runner.wait(timeout=COMPLETION_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(diagnostic(stage + ' timed out', started,
                                        COMPLETION_TIMEOUT_SECONDS)) from error
    assert status == expected, diagnostic(f'{stage}: status {status}, expected {expected}',
                                         started, COMPLETION_TIMEOUT_SECONDS)
    print(f'info {stage}: completed after {time.monotonic() - started:.2f} s '
          f'(< {COMPLETION_TIMEOUT_SECONDS} s)', flush=True)

# A permanent flock error must fail once, not spin as though it were contention.
with (root / 'followups.log').open('w') as log:
    runner = subprocess.Popen(launcher + ['-c', '. "$1"; activation_lock', '_', script],
                              env=dict(os.environ, FAKE_FLOCK_ERROR='1'), stdout=log, stderr=log)
    try:
        completed(runner, 1, 'permanent activation flock error')
    finally:
        if runner.poll() is None:
            runner.kill()
        runner.wait()
assert (root / 'flock-errors').read_text().splitlines() == ['failed']
assert 'activation lock failed (flock exit 71)' in (root / 'followups.log').read_text()
print('ok   permanent activation flock error fails once instead of retrying')

# The no-ULF watcher must not turn that fatal error into an immediate retry.
original_ulf = ulf.read_bytes()
ulf.unlink()
(root / 'flock-errors').unlink()
with (root / 'followups.log').open('w') as log:
    runner = subprocess.Popen(launcher + ['-c', '. "$1"; idle_watch', '_', script],
                              env=dict(os.environ, FAKE_FLOCK_ERROR='1'), stdout=log, stderr=log,
                              start_new_session=True)
    try:
        completed(runner, 1, 'no-ULF watcher permanent flock error')
    finally:
        if runner.poll() is None:
            os.killpg(runner.pid, signal.SIGKILL)
        runner.wait()
        ulf.write_bytes(original_ulf)
assert (root / 'flock-errors').read_text().splitlines() == ['failed']
assert (root / 'followups.log').read_text().count('activation lock failed (flock exit 71)') == 1
assert not Path(str(ulf) + '.idle/unity-idle.pid').exists()
print('ok   no-ULF watcher propagates permanent lock error once without retrying')

# A blocked activation must run wrapper EXIT cleanup while the other lock stays held.
for sig in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
    (root / 'contended').unlink(missing_ok=True)
    with Path(str(ulf) + '.lock').open('a') as lock, (root / 'followups.log').open('w') as log:
        fcntl.flock(lock, fcntl.LOCK_EX)
        runner = subprocess.Popen(launcher + [script, 'activate'], stdout=log, stderr=log)
        try:
            ready(root / 'contended', runner)
            runner.send_signal(sig)
            completed(runner, 128 + sig, f'contended activation {sig.name} cleanup')
            assert not list(Path(str(ulf) + '.idle/unity-active').glob('*'))
            assert not (root / 'out/linux-unity.pid').exists()
        finally:
            if runner.poll() is None:
                runner.kill()
            runner.wait()
    print(f'ok   contended activation {sig.name} runs cleanup without holder unlocking')

# cmd_activate prepends seat_cleanup ahead of return_on_exit. Cancellation must
# close the waiting FD before exit-return tries to lock, never bypass the holder.
original_ulf = ulf.read_bytes()
for sig in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
    (root / 'contended').unlink(missing_ok=True)
    (root / 'licensing-calls').unlink(missing_ok=True)
    with Path(str(ulf) + '.lock').open('a') as lock, (root / 'followups.log').open('w') as log:
        fcntl.flock(lock, fcntl.LOCK_EX)
        runner = subprocess.Popen(launcher + [script, 'activate'],
                                  env=dict(os.environ, UNITY_RETURN_ON_EXIT='1'), stdout=log, stderr=log)
        try:
            ready(root / 'contended', runner)
            runner.send_signal(sig)
            until(lambda: 'UNITY_RETURN_ON_EXIT=1: returning' in
                  (root / 'followups.log').read_text(), runner,
                  f'{sig.name} exit-return started while holder remains locked')
            # exit-return has started, but cannot reach licensing while locked.
            try:
                runner.wait(timeout=LOCK_BLOCKED_OBSERVATION_SECONDS)
                raise AssertionError('exit-return bypassed the held activation lock')
            except subprocess.TimeoutExpired:
                pass
            assert ulf.read_bytes() == original_ulf
            assert not (root / 'licensing-calls').exists()
            fcntl.flock(lock, fcntl.LOCK_UN)
            completed(runner, 128 + sig, f'{sig.name} exit-return after holder unlocks')
            assert (root / 'licensing-calls').read_text().splitlines() == ['called']
            assert not ulf.exists()
            assert not list(Path(str(ulf) + '.idle/unity-active').glob('*'))
        finally:
            if runner.poll() is None:
                runner.kill()
            runner.wait()
            ulf.write_bytes(original_ulf)
    print(f'ok   cancelled activation {sig.name} exit-return waits for holder and preserves signal status')

# Simulate wrapper-only TERM exactly after a trap-reset command. Restoring saved
# handlers must never reset them to defaults, including APK's opt-in EXIT chain.
code = r'''
. "$1"
trap 'echo handled > "$FAKE_TMP/handled"; exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'echo cleanup > "$FAKE_TMP/cleanup"' EXIT
trap() {
  builtin trap "$@"
  if [ "$*" = '- TERM INT HUP' ]; then kill -TERM "$$"; fi
}
activate_client
kill -TERM "$$"
'''
with (root / 'followups.log').open('w') as log:
    runner = subprocess.Popen(launcher + ['-c', code, '_', script], stdout=log, stderr=log)
    try:
        completed(runner, 143, 'saved activation handlers and EXIT cleanup')
    finally:
        if runner.poll() is None:
            runner.kill()
        runner.wait()
assert (root / 'handled').exists(), 'saved handler passed through default disposition'
assert (root / 'cleanup').exists()
print('ok   activation restores wrapper handlers without a default-disposition window')

# A return that removes a symlink's target must retain the symlink and its lock
# identity until delayed seat release completes; activation must still serialize.
target = root / 'target.ulf'
ulf.rename(target)
ulf.symlink_to(target)
code = r'''
. "$1"
seat_release() {
  : > "$FAKE_TMP/releasing"
  deadline=$((SECONDS + 60))
  while [ ! -f "$FAKE_TMP/release" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 1
    /bin/sleep 0.02
  done
}
cmd_return
'''
(root / 'contended').unlink(missing_ok=True)
with (root / 'followups.log').open('w') as log:
    returning = subprocess.Popen(launcher + ['-c', code, '_', script], stdout=log, stderr=log)
    activating = None
    try:
        ready(root / 'releasing', returning)
        assert not target.exists()
        activating = subprocess.Popen(launcher + [script, 'activate'], stdout=log, stderr=log)
        ready(root / 'contended', activating)
        assert ulf.is_symlink(), 'return removed the lock-defining symlink'
        activating.terminate()
        completed(activating, 143, 'symlinked ULF contended activation cancellation')
        (root / 'release').touch()
        completed(returning, 0, 'symlinked ULF return after delayed seat release')
    finally:
        (root / 'release').touch()
        for runner in [activating, returning]:
            if runner is not None:
                if runner.poll() is None:
                    runner.kill()
                runner.wait()
print('ok   symlinked ULF return retains shared lock identity through delayed release')
# Invalid-ULF quarantine must preserve the alias for the same reason.
target.write_text('invalid')
subprocess.run(launcher + ['-c', '. "$1"; set_aside_ulf', '_', script], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert ulf.is_symlink() and not target.exists()
assert list(root.glob('ulf.invalid-*'))
print('ok   invalid symlinked ULF quarantine preserves the shared alias')
PY
echo 'all passed'
