#!/usr/bin/env python3
"""Planted regressions for the dependency-free Tools text check."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('check_whitespace', Path(__file__).with_name('check-whitespace.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class WhitespaceTests(unittest.TestCase):
    def test_tree_and_planted_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            tools = root / 'Tools'
            tools.mkdir()
            good = tools / 'tracked file.sh'
            good.write_bytes(b'#!/bin/sh\nprintf ok\n')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            # Check the working tree, not only the index or a diff.
            self.assertEqual(checker.validate(root), [])
            for bad in (b'line \n', b'line\t\n', b'line\n\n', b'\n', b'line\r\n', b'line '):
                good.write_bytes(bad)
                self.assertTrue(checker.validate(root), repr(bad))
            good.write_bytes(b'line\n')
            (tools / 'untracked.txt').write_bytes(b'bad\n\n')
            self.assertTrue(checker.validate(root))
            (tools / 'untracked.txt').unlink()
            for name, data in [('empty', b''), ('binary', b'\0line \n\n'),
                               ('no-newline', b'line'), ('internal-blank', b'one\n\ntwo\n')]:
                (tools / name).write_bytes(data)
            (root / 'outside.txt').write_bytes(b'outside \n\n')
            (tools / 'link').symlink_to(root / 'outside.txt')
            self.assertEqual(checker.validate(root), [])


if __name__ == '__main__':
    unittest.main()
