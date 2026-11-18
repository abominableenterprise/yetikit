"""Force missing readiness records in disposable copies of the real fixtures."""

import ctypes
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


SHIP = Path(__file__).resolve().parents[2]
STOP = "linux-unity-stop.test.sh"
SEAT = "linux-unity-seat-concurrency.test.sh"
FAKE_UNITY = "lib/fake-unity.sh"
CASES = (
    ("stop/editor", STOP, FAKE_UNITY, '$FAKE_TMP/unity.pid', 'ship_read_pid', 'unity.pid'),
    ("stop/Xvfb", STOP, FAKE_UNITY, '$FAKE_TMP/xvfb.pid', 'ship_read_pid', 'xvfb.pid'),
    ("activation/stop", SEAT, SEAT, '%s/lc-started', 'test -s', 'lc-started'),
    ("activation/finish", SEAT, SEAT, '$FAKE_TMP/lc-started', 'test -s', 'lc-started'),
)


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise AssertionError(f"readiness injection no longer matches {path.name}: {old}")
    path.write_text(text.replace(old, new, 1))


def children():
    pid = os.getpid()
    return [int(p) for p in Path(f"/proc/{pid}/task/{pid}/children").read_text().split()]


def live(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1][0] != "Z"
    except FileNotFoundError:
        return False


def reap_children():
    # As subreaper we adopt even setsid/timeout workers when the test shell exits.
    # Kill only our own children, before reaping (their PIDs can't be recycled).
    deadline = time.monotonic() + 10
    while True:
        for pid in children():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if not pid:
            if time.monotonic() >= deadline:
                raise RuntimeError("could not reap synthetic fixture processes")
            time.sleep(0.02)


def run_case(label, test, source, record, predicate, name):
    with tempfile.TemporaryDirectory(prefix="ship-readiness-") as path:
        root = Path(path)
        tests = shutil.copytree(SHIP, root / "ship") / "tests"
        replace_once(tests / source, f'> "{record}"', f'> "{record}.hidden"')
        # Keep the actual readiness predicate and timeout/errexit path. Shorten only
        # the selected wait, and only once the worker has published its hidden record.
        replace_once(tests / "lib/fixture.sh", '  until "$@"; do', """  if [ "$*" = "$READINESS_PREDICATE ${!#}" ] && [ "${!#}" = "$FAKE_TMP/$READINESS_NAME" ]; then
    local marker="${!#}.hidden"
    until ship_read_pid "$marker" >/dev/null; do
      "$@" >/dev/null && break
      [ "$SECONDS" -lt "$deadline" ] || { echo "synthetic worker never reached $marker" >&2; return 1; }
      /bin/sleep 0.02
    done
    if ship_read_pid "$marker" >/dev/null; then
      printf 'observed hidden readiness: %s\\n' "$marker" >&2
      deadline=$SECONDS
    fi
  fi
  until "$@"; do""")
        home, tmp, bin_dir = (root / part for part in ("home", "tmp", "bin"))
        for directory in (home, tmp, bin_dir):
            directory.mkdir()
        for command in ("curl", "wget", "task-cache", "crane", "apt-get"):
            stub = bin_dir / command
            stub.write_text("#!/bin/sh\nexit 99\n")
            stub.chmod(0o755)
        # No credentials, host config, or Git environment from the caller.
        env = {
            "PATH": f"{bin_dir}:{os.defpath}", "HOME": str(home), "TMPDIR": str(tmp),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "LC_ALL": "C", "READINESS_PREDICATE": predicate, "READINESS_NAME": name,
        }
        log = root / "log"
        try:
            with log.open("w") as out:
                result = subprocess.run(["bash", str(tests / test)], cwd=tests,
                                        env=env, stdout=out, stderr=out, timeout=180)
            output = log.read_text()
            observed = [Path(line.removeprefix("observed hidden readiness: "))
                        for line in output.splitlines() if line.startswith("observed hidden readiness: ")]
            failed_at_readiness = (result.returncode == 1 and len(observed) == 1
                                   and observed[0].name == f"{name}.hidden"
                                   and f"fixture timed out waiting for: {predicate} {observed[0].with_suffix('')}" in output)
            survivors = [pid for pid in children() if live(pid)]
            if not failed_at_readiness:
                print(f"FAIL {label}: expected readiness failure (rc={result.returncode})")
                print(output)
                return False
            if survivors:
                print(f"FAIL {label}: readiness failed as injected; {len(survivors)} live synthetic processes escaped EXIT cleanup")
                return False
            if observed[0].parent.exists():
                print(f"FAIL {label}: EXIT did not remove the fixture sandbox")
                return False
            print(f"ok   {label}: readiness failed as injected; EXIT left no live synthetic processes")
            return True
        finally:
            reap_children()


def cancelled(signum, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise SystemExit(128 + signum)


def main():
    # Linux PR_SET_CHILD_SUBREAPER. Refuse to launch anything without the backstop.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    return 0 if all([run_case(*case) for case in CASES]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
