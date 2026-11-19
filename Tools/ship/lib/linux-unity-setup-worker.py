"""Run one setup command and drain its children with the command's privileges."""

import ctypes
import fcntl
import os
import signal
import subprocess
import sys
import time


def drain():
    # A subreaper adopts even detached grandchildren. Kill only direct children;
    # until we reap them, their PIDs cannot be reused. Repeat as orphans arrive.
    pid = os.getpid()
    children = f"/proc/{pid}/task/{pid}/children"
    while True:
        # Reap first: /proc can omit children if another child exits during
        # the read, but the next pass handles anything missed or newly adopted.
        try:
            if os.waitpid(-1, os.WNOHANG)[0]:
                continue
        except ChildProcessError:
            return
        with open(children) as handle:
            for child in handle.read().split():
                try:
                    os.kill(int(child), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        time.sleep(0.02)


def run(control, protect_int, command):
    cancelled = 0

    def remember(signum, _frame):
        nonlocal cancelled
        if not cancelled or (cancelled == 130 and signum != signal.SIGINT):
            cancelled = 128 + signum

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, remember)

    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

    with open(control) as request:
        # The caller publishes cancellation, then takes this lock exclusively.
        # A late sudo/prompt may not start a command once cancellation is visible.
        fcntl.flock(request, fcntl.LOCK_SH)

        def intent():
            request.seek(0)
            # TERM/HUP can supersede a deferred INT from either source.
            statuses = [int(line) for line in request if line.strip()]
            return next((status for status in statuses if status != 130),
                        cancelled or (130 if statuses else 0))

        status = intent()
        if status:
            return status
        # Keep the supervisor in the foreground to receive the terminal's
        # SIGINT. Noninteractive apt must not receive it, even if apt installs
        # its own handler or passes it on to dpkg.
        worker = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL if protect_int else None,
            preexec_fn=os.setpgrp if protect_int else None,
        )
        while True:
            status = intent()
            if status and not (protect_int and status == 130):
                drain()
                return status
            rc = worker.poll()
            if rc is not None:
                status = intent()
                # poll() has reaped only the leader. A failed find can
                # leave an adopted mv/rm still writing into the stage.
                if rc or (status and not (protect_int and status == 130)):
                    drain()
                    status = intent()
                return status or (rc if rc >= 0 else 128 - rc)
            time.sleep(0.05)


if __name__ == "__main__":
    sys.exit(run(sys.argv[1], sys.argv[2] == "1", sys.argv[3:]))
