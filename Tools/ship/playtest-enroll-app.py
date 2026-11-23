#!/usr/bin/env python3
"""Deliver a validated private configuration through the in-app relay."""

import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ENROLL_TIMEOUT_SECONDS = 60
LAUNCH_TIMEOUT_SECONDS = 10
RELAY_START_SECONDS = 5
RECORDER_CHECK_SECONDS = 10
REVERSE_CLEANUP_SECONDS = 2

BLOCKED = ('the headset blocked the app launch (an OS dialog is showing or the headset is not worn): '
           'put the headset on, dismiss any system dialog, and retry.')
NO_PROCESS = 'the app process did not appear for the selected Android user; check the headset and retry'
NO_DELIVERY = ('the app did not receive the configuration from the enrollment relay; '
               'check the development build and retry')
NO_RECORDER = ('configuration installed, but no fresh Playtest recorder on line was found; '
               'check the development build and launch it from a stopped state')
RECORDER_ON = re.compile(r'^Playtest recorder on(?=[\s!-/:-@\[-`{-~]|$)', re.ASCII | re.MULTILINE)


class EnrollmentError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def interrupted(signum, _frame):
    raise EnrollmentError('in-app enrollment interrupted', 128 + signum)


def test_override(name, default):
    value = os.environ.get(name, str(default))
    if not re.fullmatch(r'[0-9]{1,2}', value) or not 1 <= int(value) <= default:
        raise EnrollmentError('invalid in-app enrollment test timeout')
    return int(value)


def pause(deadline, seconds):
    time.sleep(max(0, min(seconds, deadline - time.monotonic())))


def enroll(serial, user, package, directory, verify):
    total = test_override('YETIKIT_TEST_ENROLL_TIMEOUT_SECONDS', ENROLL_TIMEOUT_SECONDS)
    launch_timeout = test_override('YETIKIT_TEST_ENROLL_LAUNCH_SECONDS', LAUNCH_TIMEOUT_SECONDS)
    deadline = time.monotonic() + total
    device = ['adb', '-s', serial]

    def adb(*args, failure, until=deadline, check=True):
        remaining = until - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(device[0], 0)
        result = subprocess.run(device + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                encoding='utf-8', errors='replace', timeout=remaining)
        if check and result.returncode:
            raise EnrollmentError(failure)
        return result

    def app_pid(until):
        result = adb('shell', 'ps', '-A', '-o', 'UID,PID,NAME', failure='', until=until, check=False)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                fields = line.split()
                # Android encodes the profile in the UID (PER_USER_RANGE = 100000).
                if (len(fields) == 3 and fields[2] == package and re.fullmatch(r'[0-9]{1,10}', fields[0])
                        and int(fields[0]) // 100000 == int(user) and re.fullmatch(r'[1-9][0-9]*', fields[1])):
                    return fields[1]
        return None

    relay = None
    reverse = None
    try:
        relay = subprocess.Popen(['python3', str(Path(__file__).with_name('playtest-enroll-relay.py')),
                                 str(directory), str(deadline)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready = directory / 'relay-ready'
        ready_deadline = min(deadline, time.monotonic() + RELAY_START_SECONDS)
        while not ready.exists() and relay.poll() is None and time.monotonic() < ready_deadline:
            pause(ready_deadline, 0.1)
        if not ready.is_file():
            raise EnrollmentError('could not initialize the local enrollment relay (configuration must fit in 16 KiB)')
        match = re.fullmatch(r'([0-9]{1,5}) ([0-9a-f]{32})\n', ready.read_text(encoding='ascii'))
        if not match:
            raise EnrollmentError('could not initialize the local enrollment relay')
        port, nonce = match.groups()
        address = f'tcp:{port}'
        # Do not replace or remove a mapping owned by another adb client.
        adb('reverse', '--no-rebind', address, address,
            failure='could not set up adb reverse; check device connectivity and retry')
        reverse = address
        resolved = adb('shell', 'cmd', 'package', 'resolve-activity', '--brief', '--user', user, package,
                       failure='could not resolve the configured app launcher activity').stdout.splitlines()
        activity = resolved[-1] if resolved else ''
        if not activity.startswith(package + '/') or not re.fullmatch(r'[A-Za-z0-9_.$]+', activity.split('/', 1)[1]):
            raise EnrollmentError('could not resolve the configured app launcher activity')
        clock = adb('shell', 'date', '+%s.%N', failure='could not read the device clock').stdout
        stamp = re.fullmatch(r'([0-9]+\.[0-9]{3})[0-9]*\n?', clock)
        if not stamp:
            raise EnrollmentError('unexpected device clock format')
        since = stamp[1]
        user_error = 'could not re-check the foreground Android user; retry with the intended profile active'
        current = adb('shell', 'am', 'get-current-user', failure=user_error).stdout.rstrip('\n')
        if not re.fullmatch(r'[0-9]+', current):
            raise EnrollmentError(user_error)
        if current != user:
            raise EnrollmentError('the foreground Android user changed during enrollment; '
                                  'switch back to the intended profile and retry')
        # Do not use -W: Android can keep the launch request pending behind a system dialog.
        # adb joins remote argv; quote the validated component to protect nested class names.
        started = adb('shell', 'am', 'start', '--user', user, '-S', '-n', f"'{activity}'",
                      '--ei', 'yetikit_enroll_port', port, '--es', 'yetikit_enroll_nonce', nonce,
                      failure='', check=False)
        launch_deadline = min(deadline, time.monotonic() + launch_timeout)
        try:
            while time.monotonic() < launch_deadline:
                logs = adb('logcat', '-d', '-T', since, '-v', 'raw', failure='', until=launch_deadline, check=False)
                if logs.returncode == 0 and re.search(r'^Launch is blocked\b', logs.stdout, re.MULTILINE):
                    raise EnrollmentError(BLOCKED, 2)
                if started.returncode or 'Error:' in started.stdout or 'Error:' in started.stderr:
                    raise EnrollmentError('could not launch the configured app')
                if app_pid(launch_deadline):
                    break
                pause(launch_deadline, 0.25)
            else:
                raise EnrollmentError(NO_PROCESS, 3)
        except subprocess.TimeoutExpired:
            raise EnrollmentError(NO_PROCESS, 3) from None

        # The relay exits successfully only after it has served the config once.
        try:
            served = relay.wait(timeout=max(0, deadline - time.monotonic())) == 0
        except subprocess.TimeoutExpired:
            served = False
        if not served:
            raise EnrollmentError(NO_DELIVERY, 4)
        (directory / 'playtest.json').unlink()
        print('Playtest configuration delivered to the app.')
        if verify:
            verify_deadline = min(deadline, time.monotonic() + RECORDER_CHECK_SECONDS)
            try:
                while time.monotonic() < verify_deadline:
                    pid = app_pid(verify_deadline)
                    if pid:
                        logs = adb('logcat', '-d', '-T', since, f'--pid={pid}', '-v', 'raw', '-s', 'Unity:V',
                                   failure='', until=verify_deadline, check=False)
                        if logs.returncode == 0 and RECORDER_ON.search(logs.stdout):
                            print('Playtest recorder confirmed on.')
                            return
                    pause(verify_deadline, 1)
            except subprocess.TimeoutExpired:
                pass
            raise EnrollmentError(NO_RECORDER)
    finally:
        # Finish cleanup even when the caller signals the entire process group.
        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        if relay is not None and relay.poll() is None:
            relay.kill()
            relay.wait()
        if reverse is not None:
            try:
                # Cleanup gets a short, independent allowance even when the route timed out.
                adb('reverse', '--remove', reverse, until=time.monotonic() + REVERSE_CLEANUP_SECONDS,
                    failure='could not remove the adb reverse mapping')
            except (EnrollmentError, OSError, subprocess.TimeoutExpired):
                print('[playtest-enroll] could not remove the adb reverse mapping; '
                      'reconnect the device and clear the mapping', file=sys.stderr)


if __name__ == '__main__':
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        enroll(*sys.argv[1:4], Path(sys.argv[4]), sys.argv[5] == '1')
    except EnrollmentError as exc:
        print(f'[playtest-enroll] {exc}', file=sys.stderr)
        sys.exit(exc.code)
    except subprocess.TimeoutExpired:
        print('[playtest-enroll] in-app enrollment timed out waiting for adb; check device connectivity and retry',
              file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError):
        print('[playtest-enroll] could not complete in-app enrollment', file=sys.stderr)
        sys.exit(1)
