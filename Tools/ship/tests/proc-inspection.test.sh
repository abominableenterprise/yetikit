#!/usr/bin/env bash
# Missing process inspection is reported rather than a vacuous leak-check pass.
set -euo pipefail
python3 -B - "$(dirname "$0")/helpers" <<'PY'
import contextlib
import io
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, sys.argv[1])
from proc_inspection import available, cleanup_session, marked, require, wait_marked

with tempfile.TemporaryDirectory() as directory:
    proc = Path(directory) / 'missing-proc'
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert not require('planted leak assertion', proc)
    assert 'SKIP: planted leak assertion' in output.getvalue()
    (proc / 'self').mkdir(parents=True)
    (proc / 'self/environ').write_bytes(b'SYNTHETIC=1\0')
    read_bytes = Path.read_bytes

    def restrict_descendants(path):
        if path.name == 'environ' and path.parent.name.isdecimal():
            raise PermissionError('synthetic restricted descendant environment')
        return read_bytes(path)

    def allow_descendants(path):
        if path.name == 'environ' and path.parent.name.isdecimal():
            return b'SHIP_PROC_PROBE=synthetic\0'
        return read_bytes(path)

    output = io.StringIO()
    with patch.object(Path, 'read_bytes', allow_descendants), contextlib.redirect_stdout(output):
        assert require('readable descendant assertion', proc)
    assert not output.getvalue()

    with patch.object(Path, 'read_bytes', restrict_descendants):
        assert (proc / 'self/environ').read_bytes() == b'SYNTHETIC=1\0'
        assert not available(proc), 'readable self does not prove readable descendants'
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            assert not require('restricted descendant assertion', proc)
        assert 'SKIP: restricted descendant assertion' in output.getvalue()

    def process(pid, state, group, session):
        entry = proc / str(pid)
        entry.mkdir()
        # Reparented processes can retain the fixture's session but not its group.
        (entry / 'stat').write_text(f'{pid} (synthetic ) name) {state} 1 {group} {session}\n')
        return entry / 'environ'

    child = process(102, 'S', 102, 101)
    process(201, 'S', 201, 201)  # Unrelated, unreadable environment.
    process(103, 'Z', 102, 101)  # Exited fixture member needs no environment read.
    marker = b'FIXTURE=synthetic'
    child.write_bytes(marker + b'\0')
    assert marked('readable leak', marker, 101, proc) == [102]
    for error in (PermissionError, FileNotFoundError, ProcessLookupError):
        def unreadable(path):
            if path == child:
                raise error('synthetic descendant read error')
            return read_bytes(path)

        output = io.StringIO()
        with patch.object(Path, 'read_bytes', unreadable), contextlib.redirect_stdout(output):
            assert marked('restricted leak scan', marker, 101, proc) is None
        assert 'SKIP: restricted leak scan' in output.getvalue()
    child.write_bytes(b'')
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert marked('empty descendant environment', marker, 101, proc) is None
    assert 'SKIP: empty descendant environment' in output.getvalue()
    known = process(104, 'S', 102, 101)
    known.write_bytes(marker + b'\0')
    assert marked('known leak despite an unreadable member', marker, 101, proc) == [104]
    known.with_name('stat').unlink()
    child.write_bytes(b'FIXTURE=other\0')
    assert marked('readable clean scan', marker, 101, proc) == []

    def exited(path):
        if path == child:
            child.with_name('stat').unlink()
            raise ProcessLookupError('synthetic descendant exit')
        return read_bytes(path)

    with patch.object(Path, 'read_bytes', exited):
        assert marked('descendant exited during scan', marker, 101, proc) == []
print('ok   restricted descendant environments are explicitly skipped, not reported clean')


class ProcRaces(unittest.TestCase):
    marker = b'FIXTURE=synthetic'
    session = 301
    worker = 302

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.proc = Path(directory.name)
        self.child = self.proc / str(self.worker)
        self.child.mkdir()
        self.stat = self.child / 'stat'
        self.stat.write_bytes(b'302 (fixture) S 1 302 301\n')
        self.environ = self.child / 'environ'
        self.environ.write_bytes(self.marker + b'\0')
        self.unrelated = self.proc / '401'
        self.unrelated.mkdir()
        (self.unrelated / 'stat').write_bytes(b'401 (unrelated) S 1 401 401\n')
        self.unreadable = set()
        for mock in (patch.object(Path, 'iterdir', lambda path: iter((self.unrelated, self.child))),
                     patch.object(Path, 'read_bytes', lambda path: self.read_bytes(path))):
            mock.start()
            self.addCleanup(mock.stop)

    def read_bytes(self, path):
        if path in self.unreadable:
            raise PermissionError('synthetic restricted proc entry')
        return read_bytes(path)

    def test_scan_continues_after_unreadable_stat(self):
        self.unreadable.add(self.unrelated / 'stat')
        self.assertEqual(marked('later readable leak', self.marker, self.session), [self.worker])
        self.environ.write_bytes(b'FIXTURE=other\0')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertIsNone(marked('unknown session membership', self.marker, self.session))
        self.assertIn('SKIP: unknown session membership', output.getvalue())

    def test_cleanup_continues_after_unreadable_stat(self):
        self.unreadable.add(self.unrelated / 'stat')
        process = Mock(pid=self.session)
        with patch('proc_inspection.os.killpg') as killpg, patch('proc_inspection.os.kill') as kill:
            cleanup_session(process)
        killpg.assert_called_once_with(self.session, signal.SIGKILL)
        kill.assert_called_once_with(self.worker, signal.SIGKILL)
        process.wait.assert_called_once_with(timeout=5)

    def test_observed_leak_survives_unreadable_entry(self):
        for path in (self.environ, self.stat):
            with self.subTest(file=path.name):
                self.unreadable.clear()
                with patch('proc_inspection.time.monotonic', side_effect=[0, 0, 2]), \
                        patch('proc_inspection.time.sleep', side_effect=lambda _: self.unreadable.add(path)), \
                        contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(wait_marked('observed live leak', self.marker, self.session), [self.worker])
                self.assertNotIn('SKIP', output.getvalue())

    def test_observed_leak_can_exit_between_polls(self):
        def exit_after_first_poll(_):
            self.stat.unlink()
            self.unreadable.add(self.environ)

        with patch('proc_inspection.time.monotonic', side_effect=[0, 0, 2]), \
                patch('proc_inspection.time.sleep', side_effect=exit_after_first_poll):
            self.assertEqual(wait_marked('observed process exited', self.marker, self.session), [])


unittest.main(argv=[sys.argv[0]])
PY
