#!/usr/bin/env bash
# Cancellation and APK wrapper lifecycle regressions. Stubs only; no Unity/network.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$repo/Tools/ship/linux-unity.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
proj="$tmp/proj"; mkdir -p "$proj/Packages" "$proj/ProjectSettings"
printf '{}\n' > "$proj/Packages/manifest.json"
printf '{}\n' > "$proj/Packages/packages-lock.json"
echo 'm_EditorVersion: 6000.6.6f1' > "$proj/ProjectSettings/ProjectVersion.txt"
. "$repo/Tools/ship/tests/lib/fake-unity.sh"
git_init
mkdir -p "$UNITY_ROOT/Editor/Data/PlaybackEngines/AndroidPlayer/"{SDK,NDK}
lc="$UNITY_ROOT/Editor/Data/Resources/Licensing/Client/Unity.Licensing.Client"
mkdir -p "$(dirname "$lc")"
# Model a client ignoring INT explicitly: shell/setsid startup can reset inherited ignores.
cat > "$lc" <<'EOF'
#!/bin/bash
[ "$1" = --activate-ulf ] || exit 0
trap '' INT
if [ "${STUB_STUBBORN:-0}" = 1 ]; then trap '' TERM; fi
echo $$ > "$FAKE_TMP/client.pid"
if [ "${STUB_FORK:-0}" = 1 ]; then
  bash -c 'trap "" TERM; echo $$ > "$FAKE_TMP/worker.pid"; exec /bin/sleep 300' &
  # Publish readiness only once the forking client's worker has installed its trap.
  deadline=$((SECONDS + 60))
  while [ ! -s "$FAKE_TMP/worker.pid" ]; do
    [ "$SECONDS" -lt "$deadline" ] || exit 1
    /bin/sleep 0.02
  done
  : > "$FAKE_TMP/client.ready"
  wait
else
  : > "$FAKE_TMP/client.ready"
  exec /bin/sleep 300
fi
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
cat >/dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) shift; echo "$1" >> "$FAKE_TMP/seat-calls" ;;
    -D) shift; : > "$1" ;;
    -o) shift; echo '{"status":"acquired"}' > "$1" ;;
  esac
  shift
done
printf 200
EOF
chmod +x "$lc" "$tmp/bin/curl"
export THEROBOTS_HUB_URL=hub-origin THEROBOTS_TASK_ID=fixture THEROBOTS_TASK_TOKEN=fake
export APK_MIN_FREE_GB=0 APK_MIN_FREE_GB_WARM=0 APK_SWAP_GB=0
python3 - "$script" <<'PY'
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ['FAKE_TMP'])
out = Path(os.environ['OUT_DIR'])
ulf = Path(os.environ['ULF'])
script = sys.argv[1]

# activation_signal gives a stubborn client 100 separate 20 ms sleeps before
# KILL. Scheduler delays under CPU load can stretch that nominal 2 s grace
# beyond 6 s, and wrapper cleanup still has to finish afterwards. Wait for
# actual process completion, not a fixed sleep; allow scheduling headroom but
# stay far below the stub client's 300 s lifetime so a missed cancel fails.
CANCELLATION_TIMEOUT_SECONDS = 30

def until(condition, seconds=60):
    deadline = time.monotonic() + seconds
    while not condition():
        if time.monotonic() >= deadline:
            raise AssertionError('fixture deadline exceeded')
        time.sleep(.02)

def gone(pid):
    return not Path(f'/proc/{pid}').exists()

# INT must work for a client ignoring it. TERM must also escalate for a
# stubborn client, and wrapper-only APK TERM must not build.
cases = [('activate', signal.SIGINT, False),
                                ('activate', signal.SIGINT, True),
                                ('activate', signal.SIGTERM, True),
         ('apk', signal.SIGTERM, False)]
cases = [(command, sig, stubborn, False) for command, sig, stubborn in cases] + [
    ('activate', signal.SIGTERM, False, True),
    ('apk', signal.SIGINT, True, True)]
for command, sig, stubborn, fork in cases:
    for path in [ulf, root / 'client.pid', root / 'client.ready', root / 'worker.pid',
                 root / 'seat-calls', root / 'runs']:
        path.unlink(missing_ok=True)
    env = dict(os.environ, STUB_STUBBORN=str(int(stubborn)), STUB_FORK=str(int(fork)))
    client = worker = None
    with (root / 'cancel.log').open('w') as log:
        # Reset inherited ignores BEFORE Bash starts: Bash cannot un-ignore INT
        # at shell entry. Use the same Perl exec launcher as the quest-release fixtures.
        runner = subprocess.Popen(['perl', '-e',
            '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV; die "exec: $!"',
            'bash', script, command], env=env, stdout=log, stderr=log)
        try:
            until(lambda: (root / 'client.ready').exists() or runner.poll() is not None)
            assert runner.poll() is None, (root / 'cancel.log').read_text()
            client = int((root / 'client.pid').read_text())
            if fork:
                worker = int((root / 'worker.pid').read_text())
            else:
                # client.ready precedes exec. Wait for the final executable so
                # /proc cannot sample Bash's transient exec-time signal setup.
                until(lambda: Path(f'/proc/{client}/exe').resolve() == Path('/bin/sleep').resolve())
            # Confirm the client really ignores INT before cancelling the wrapper.
            ignored = next(line.split()[1] for line in Path(f'/proc/{client}/status').read_text().splitlines()
                           if line.startswith('SigIgn:'))
            assert int(ignored, 16) & (1 << (signal.SIGINT - 1)), (command, sig, stubborn, fork, ignored)
            cancelled_at = time.monotonic()
            runner.send_signal(sig)
            try:
                status = runner.wait(timeout=CANCELLATION_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(
                    f'{command} {sig.name}, stubborn={stubborn}, fork={fork}: '
                    f'cancellation exceeded {CANCELLATION_TIMEOUT_SECONDS} s\n'
                    + (root / 'cancel.log').read_text()) from error
            cancellation_seconds = time.monotonic() - cancelled_at
            assert status == 128 + sig, (status, (root / 'cancel.log').read_text())
            assert gone(client), 'client not reaped'
            if worker:
                # An orphan may await init's reaper, but cannot remain a running worker.
                assert not Path(f'/proc/{worker}/stat').exists() or (
                    Path(f'/proc/{worker}/stat').read_text().split()[2] == 'Z'), 'activation worker survived'
            assert not (out / 'unity-seat.held').exists()
            assert (root / 'seat-calls').read_text().splitlines() == [
                '{"action":"acquire"}', '{"action":"release"}']
            assert not (root / 'runs').exists(), 'build started after cancellation'
            assert not (out / 'linux-unity.pid').exists()
            assert not list(Path(str(ulf.resolve()) + '.idle/unity-active').glob('*'))
            # Neither failure nor escalation may leave the shared lock held.
            with Path(str(ulf.resolve()) + '.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if worker and not gone(worker):
                os.kill(worker, signal.SIGKILL)
            if client and not gone(client):
                os.kill(client, signal.SIGKILL)
            if runner.poll() is None:
                runner.kill()
            runner.wait()
    print(f'ok   {command} wrapper-only {sig.name}, stubborn={stubborn}, fork={fork}: '
          f'bounded cancellation ({cancellation_seconds:.2f} s < {CANCELLATION_TIMEOUT_SECONDS} s), '
          'reaping and seat release', flush=True)
PY
# Re-activation must not copy the wrapper's EXIT chain into an APK subshell.
# Block actual noise restoration and cold-cache saving to inspect discoverability
# after the editor exits, with return-on-exit enabled to catch early returns too.
cat > "$lc" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE_TMP/lc-calls"
[ "$1" != --activate-ulf ] || echo '<root><License/><Signature>x</Signature></root>' > "$ULF"
EOF
cat > "$tmp/bin/git" <<'EOF'
#!/bin/sh
if [ -f "$FAKE_TMP/editor-done" ] && [ "$1" = -C ] && [ "$3" = rev-parse ]; then
  : > "$FAKE_TMP/noise-blocked"
  while [ ! -f "$FAKE_TMP/noise-continue" ]; do /bin/sleep 0.02; done
fi
exec /usr/bin/git "$@"
EOF
cat > "$tmp/bin/fake-cache" <<'EOF'
#!/bin/sh
[ "$1" = save ] || exit 3
: > "$FAKE_TMP/cache-blocked"
while [ ! -f "$FAKE_TMP/cache-continue" ]; do /bin/sleep 0.02; done
EOF
chmod +x "$lc" "$tmp/bin/git" "$tmp/bin/fake-cache"
rm -rf "$proj/Library"; rm -f "$ULF"
export TASK_CACHE=fake-cache UNITY_RETURN_ON_EXIT=1
export FAKE_MUTATE='mkdir -p Builds/Android; echo apk > Builds/Android/GeneratedScene-dev.apk; touch "$FAKE_TMP/editor-done"'
python3 - "$script" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(os.environ['FAKE_TMP'])
out = Path(os.environ['OUT_DIR'])
ulf = Path(os.environ['ULF'])
# These gates measure lifecycle ownership, not cancellation latency. Wait on
# their explicit markers with enough budget for a loaded runner's APK setup.
LIFECYCLE_TIMEOUT_SECONDS = 60
with (root / 'lifecycle.log').open('w') as log:
    runner = subprocess.Popen(['perl', '-e',
        '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV; die "exec: $!"',
        'bash', sys.argv[1], 'apk'], stdout=log, stderr=log)
    try:
        for stage in ['noise', 'cache']:
            deadline = time.monotonic() + LIFECYCLE_TIMEOUT_SECONDS
            while not (root / f'{stage}-blocked').exists():
                assert runner.poll() is None, (root / 'lifecycle.log').read_text()
                assert time.monotonic() < deadline, f'{stage} never reached'
                time.sleep(.02)
            assert int((out / 'linux-unity.pid').read_text().split()[0]) == runner.pid
            assert len(list(Path(str(ulf.resolve()) + '.idle/unity-active').glob(f'{runner.pid}:*'))) == 1
            assert ulf.exists(), 'licence returned before post-build processing'
            assert '--return-ulf' not in (root / 'lc-calls').read_text()
            (root / f'{stage}-continue').touch()
            print(f'ok   parent pidfile, activity marker and licence survive APK {stage} processing')
        assert runner.wait(timeout=LIFECYCLE_TIMEOUT_SECONDS) == 0
        assert not (out / 'linux-unity.pid').exists()
        assert not list(Path(str(ulf.resolve()) + '.idle/unity-active').glob('*'))
        assert not ulf.exists()
        assert (root / 'lc-calls').read_text().splitlines().count('--return-ulf') == 1
    finally:
        for stage in ['noise', 'cache']:
            (root / f'{stage}-continue').touch()
        if runner.poll() is None:
            runner.terminate()
        runner.wait(timeout=LIFECYCLE_TIMEOUT_SECONDS)
PY
echo 'all passed'
