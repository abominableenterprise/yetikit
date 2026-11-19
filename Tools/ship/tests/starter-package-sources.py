"""Exercise the verification command copied into a freshly generated starter."""
import json
from pathlib import Path
import subprocess
import sys

project = Path(sys.argv[1])
packages = project / 'Packages'
manifest = packages / 'manifest.json'
lock = packages / 'packages-lock.json'
direct = json.loads(manifest.read_text())['dependencies']
kit = next(name for name in direct if name.startswith('com.abominable.yetikit.'))


def verify(error=None, *args):
    result = subprocess.run(
        [sys.executable, '-B', str(project / 'verify-packages.py'), *args],
        cwd=project, capture_output=True, text=True,
    )
    if error is None:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0 and error in result.stderr, result


verify('packages-lock.json')
verify(None, '--manifest-only')
locked = {name: {'version': version, 'source': 'git' if name.startswith('com.abominable.yetikit.') else 'registry'}
          for name, version in direct.items()}
locked['com.unity.inputsystem']['url'] = 'https://registry.invalid'


def write(path, entries):
    path.write_text(json.dumps({'dependencies': entries}), encoding='utf-8')


write(lock, locked)
verify()
for version in ('file:../../Packages/example', '../Packages/example', '/tmp/example',
                r'C:\packages\example', 'Packages/example'):
    # A non-kit path must fail too; the kit check has the additional canonical-URL rule.
    write(manifest, {**direct, 'fixture.local': version})
    verify('manifest.json: fixture.local', '--manifest-only')
    write(manifest, direct)
    write(lock, {**locked, 'fixture.local': {'version': version, 'source': 'git'}})
    verify('packages-lock.json: fixture.local')

write(manifest, {**direct, kit: 'https://fixture.invalid/example'})
verify(f'manifest.json: {kit}', '--manifest-only')
write(manifest, direct)
write(lock, {**locked, kit: {**locked[kit], 'dependencies': {'fixture.local': 'file:../../example'}}})
verify('packages-lock.json: fixture.local', '--manifest-only')
write(lock, {**locked, 'fixture.local': {'version': '1.0.0', 'source': 'registry', 'url': 'file:///tmp/registry'}})
verify('packages-lock.json: fixture.local')

for source in ('local', 'local-tarball', 'embedded'):
    write(lock, {**locked, kit: {**locked[kit], 'source': source}})
    verify(f'packages-lock.json: {kit}')

write(lock, {**locked, kit: {**locked[kit], 'version': direct[kit].split('#')[0] + '#other'}})
verify(f'packages-lock.json: {kit}')
write(lock, locked)
(packages / 'fixture.embedded').mkdir()
(packages / 'fixture.embedded' / 'package.json').write_text('{}', encoding='utf-8')
verify('fixture.embedded')
