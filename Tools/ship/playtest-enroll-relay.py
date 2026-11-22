#!/usr/bin/env python3
"""Serve a private enrolment file once to an authenticated adb reverse client."""

import hmac
from pathlib import Path
import secrets
import socket
import sys
import time

MAX_CONFIG_BYTES = 16 * 1024
CLIENT_TIMEOUT_SECONDS = 2


def serve(directory, timeout):
    with (directory / 'playtest.json').open('rb') as config:
        payload = config.read(MAX_CONFIG_BYTES + 1)
    if not 0 < len(payload) <= MAX_CONFIG_BYTES:
        return False
    nonce = secrets.token_hex(16)
    expected = nonce.encode('ascii') + b'\n'
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        deadline = time.monotonic() + timeout
        ready = directory / 'relay-starting'
        ready.write_text(f'{listener.getsockname()[1]} {nonce}\n', encoding='ascii')
        ready.replace(directory / 'relay-ready')
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            listener.settimeout(max(0, remaining))
            try:
                client, _ = listener.accept()
            except (TimeoutError, BlockingIOError):
                break
            with client:
                client_deadline = min(deadline, time.monotonic() + CLIENT_TIMEOUT_SECONDS)
                try:
                    received = b''
                    while len(received) < len(expected):
                        remaining = client_deadline - time.monotonic()
                        if remaining <= 0:
                            break
                        client.settimeout(remaining)
                        chunk = client.recv(len(expected) - len(received))
                        if not chunk:
                            break
                        received += chunk
                except OSError:
                    continue
                if not hmac.compare_digest(received, expected):
                    continue
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                client.settimeout(remaining)
                # A matching nonce is consumed even if the transfer fails.
                client.sendall(payload)
                return True
    return False


if __name__ == '__main__':
    try:
        sys.exit(0 if serve(Path(sys.argv[1]), int(sys.argv[2])) else 1)
    except OSError:
        sys.exit(1)
