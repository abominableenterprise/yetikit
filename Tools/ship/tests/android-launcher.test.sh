#!/usr/bin/env bash
# Synthetic source manifest and APK contracts; no SDK, network, editor or device.
# Even subprocess cases run here; android-launcher-odd.test.sh covers the rest.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/../android-launcher.py"
manifest="$here/fixtures/android-launcher/AndroidManifest.xml"
python3 - "$check" "$manifest" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

check, manifest = sys.argv[1:]
game = "com.unity3d.player.UnityPlayerGameActivity"
permission = "android.permission.RECORD_AUDIO"
asset = "assets/synthetic-payload.bin"
package = "com.example.consumer"
vr = '        E: category (line=10)\n          A: android:name(0x01010003)="com.oculus.intent.category.VR" (Raw: "com.oculus.intent.category.VR")\n'
metadata = '      E: meta-data (line=11)\n        A: android:name(0x01010003)="android.app.lib_name" (Raw: "android.app.lib_name")\n        A: android:value(0x01010024)="game" (Raw: "game")\n'
launcher = '''      E: intent-filter (line=7)
        E: action (line=8)
          A: android:name(0x01010003)="android.intent.action.MAIN" (Raw: "android.intent.action.MAIN")
        E: category (line=9)
          A: android:name(0x01010003)="android.intent.category.LAUNCHER" (Raw: "android.intent.category.LAUNCHER")
'''
exported = '      A: android:exported(0x01010010)=(type 0x12)0xffffffff\n'
activity = f'''    E: activity (line=5)
      A: android:theme(0x01010000)=@0x7f030001
      A: android:name(0x01010003)="{game}" (Raw: "{game}")
''' + exported
header = '''N: android=http://schemas.android.com/apk/res/android
E: manifest (line=1)
  E: application (line=3)
'''
main = ''.join(launcher.splitlines(True)[1:3])
category = ''.join(launcher.splitlines(True)[3:])
filter_start = '      E: intent-filter (line=12)\n'
valid = header + activity + launcher + vr + metadata
other = activity.replace(game, "com.example.OtherActivity")
mutations = {
    "VR in another GameActivity filter": header + activity + launcher + filter_start + vr + metadata,
    "VR in another activity": header + activity + launcher + metadata + other + launcher + vr,
    "MAIN in another filter": header + activity + filter_start + category + vr + filter_start + main + metadata,
    "LAUNCHER in another filter": header + activity + filter_start + main + vr + filter_start + category + metadata,
    "missing library metadata": valid.replace(metadata, ''),
    "changed library value": valid.replace('="game"', '="other"').replace('Raw: "game"', 'Raw: "other"'),
    "changed library name": valid.replace('android.app.lib_name', 'android.app.other'),
    "library metadata on another activity": header + activity + launcher + vr + other + metadata,
    "library metadata on application": header + ''.join(line[2:] for line in metadata.splitlines(True)) + activity + launcher + vr,
    "theme on another activity": valid.replace('@0x7f030001', '@0x7f030002') + other,
    "missing decoded manifest": '',
}
export_mutations = {
    "not exported": valid.replace('0xffffffff', '0x0') + other + launcher,
    "missing exported": valid.replace(exported, ''),
    "integer instead of exported boolean": valid.replace('(type 0x12)', '(type 0x10)'),
}
positives = {
    "valid": valid,
    "valid with nonzero typed boolean": valid.replace('0xffffffff', '0x1'),
    "valid with unrelated activity first": header + other + launcher + activity + launcher + vr + metadata,
    "valid with unrelated activity last": valid + other + launcher,
}
failures = []
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    config = path / 'yetikit.json'
    settings = {
        'schema': 1, 'unityVersion': '6000.6.6f1',
        'build': {'devMethod': 'Synthetic.Build.Dev', 'releaseMethod': 'Synthetic.Build.Release',
                  'apkPath': 'Builds/Android/consumer.apk'},
        'quest': {'package': package, 'launcherChecks': {'permissions': [permission], 'assets': [asset]}},
    }
    config.write_text(json.dumps(settings))

    shard = int(os.environ.get('LAUNCHER_TEST_SHARD', '0'))
    ordinal = 0

    def run(target, expected, label, configured=True, contest=False, error=None):
        global ordinal
        ordinal += 1
        if ordinal % 2 != shard:
            return
        args = [sys.executable, check]
        if contest:
            args += ['--contest']
        if configured:
            args += ['--config', str(config)]
        result = subprocess.run(args + [str(target)], capture_output=True, text=True,
                                env={**os.environ, 'AAPT': str(path / 'aapt')})
        if (result.returncode == 0) != expected or (error is not None and error not in result.stderr):
            failures.append(f'{label}: exit {result.returncode}: {result.stdout}{result.stderr}')

    # Source checks remain mandatory with no config and with empty optional checks.
    source = Path(manifest).read_text()
    mutated = path / 'manifest.xml'
    run(manifest, False, 'config is required', False)
    for configured in (True,):
        run(manifest, True, f'valid source configured={configured}', configured)
        for label, text in {
            'theme': source.replace('@style/BaseUnityGameActivityTheme', '@style/OtherTheme'),
            'VR': source.replace('com.oculus.intent.category.VR', 'com.example.UNRELATED'),
            'metadata': source.replace('android.app.lib_name', 'android.app.other'),
            'exported': source.replace('android:exported="true"', 'android:exported="false"'),
            'launcher': source.replace('android.intent.category.LAUNCHER', 'com.example.UNRELATED'),
        }.items():
            mutated.write_text(text)
            run(mutated, False, f'missing source {label} configured={configured}', configured)
    stripped_source = source.replace(f'  <uses-permission android:name="{permission}" />\n', '')
    mutated.write_text(stripped_source)
    run(mutated, False, 'configured permission required')
    run(manifest, False, 'contest rejects configured source permission', contest=True)
    run(mutated, True, 'contest accepts source with configured permission absent', contest=True)
    for tag in ('uses-permission-sdk-23', 'uses-permission-sdk-m'):
        mutated.write_text(source.replace('<uses-permission ', f'<{tag} '))
        run(mutated, True, f'{tag} source permission satisfies requirement')
        run(mutated, False, f'contest rejects {tag} source permission', contest=True,
            error='contest build ships permission ' + permission)
    for label, text in {
        'VR': stripped_source.replace('com.oculus.intent.category.VR', 'com.example.UNRELATED'),
        'theme': stripped_source.replace('@style/BaseUnityGameActivityTheme', '@style/OtherTheme'),
        'metadata': stripped_source.replace('android.app.lib_name', 'android.app.other'),
        'exported': stripped_source.replace('android:exported="true"', 'android:exported="false"'),
    }.items():
        mutated.write_text(text)
        run(mutated, False, f'contest retains source {label} contract', contest=True)
    mutated.write_text(stripped_source)
    settings['quest']['launcherChecks'] = {'permissions': [], 'assets': []}
    config.write_text(json.dumps(settings))
    run(mutated, True, 'empty optional source checks')
    run(manifest, True, 'contest empty checks impose no implicit permission ban', contest=True)
    run(mutated, False, 'missing config does not bypass source guard', False)

    apk = path / 'fixture.apk'
    decoder = path / 'aapt'
    decoder.write_text('#!/bin/sh\ncase "$2" in\n badging|xmltree|resources) cat "$3.$2" ;;\n *) exit 1 ;;\nesac\n')
    decoder.chmod(0o755)
    resources = path / 'fixture.apk.resources'
    theme = 'spec resource 0x7f030001 com.example:style/BaseUnityGameActivityTheme: flags=0x00000000\n'
    resources.write_text(theme)

    def make_apk(*, payload=True, mic=True, application_id=package, permission_tag='uses-permission'):
        badging = f"package: name='{application_id}'\nlaunchable-activity: name='{game}'\n"
        if mic:
            badging += f"{permission_tag}: name='{permission}'\n"
        (path / 'fixture.apk.badging').write_text(badging)
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('AndroidManifest.xml', 'decoded manifest supplied by synthetic aapt')
            if payload:
                archive.writestr(asset, 'synthetic')

    for checks in ({'permissions': [], 'assets': []}, {'permissions': [permission], 'assets': [asset]}):
        settings['quest']['launcherChecks'] = checks
        config.write_text(json.dumps(settings))
        make_apk()
        for label, tree in {**positives, **mutations}.items():
            (path / 'fixture.apk.xmltree').write_text(tree)
            run(apk, label in positives, f'APK {label}, checks={checks}')

    # Contest mode inverts only configured permissions/assets, not the Unity contract.
    for label, tree in {**positives, **mutations}.items():
        (path / 'fixture.apk.xmltree').write_text(tree)
        make_apk(payload=False, mic=False)
        run(apk, label in positives, f'contest APK {label}', contest=True)
    for label, tree in export_mutations.items():
        (path / 'fixture.apk.xmltree').write_text(tree)
        make_apk()
        run(apk, False, f'APK {label}', error='GameActivity not exported')
        make_apk(payload=False, mic=False)
        run(apk, False, f'contest APK {label}', contest=True, error='GameActivity not exported')

    # Match aapt dump xmltree/resources output for a compiled @bool reference.
    tree = valid.replace('(type 0x12)0xffffffff', '@0x7f040000')
    (path / 'fixture.apk.xmltree').write_text(tree)
    export_spec = '      spec resource 0x7f040000 com.example:bool/launcher_exported: flags=0x00000000\n'
    export_entry = '        resource 0x7f040000 com.example:bool/launcher_exported: '
    alias_entry = '        resource 0x7f040001 com.example:bool/export_alias: '
    true_value = 't=0x12 d=0xffffffff (s=0x0008 r=0x00)\n'
    false_value = 't=0x12 d=0x00000000 (s=0x0008 r=0x00)\n'
    default = '      config (default):\n'
    for label, resolved, values in (
        ('true bool reference', True, default + export_entry + true_value),
        ('false bool reference', False, default + export_entry + false_value),
        ('unresolved bool reference', False, ''),
        ('non-boolean resource', False, default + export_entry + true_value.replace('t=0x12', 't=0x10')),
        ('bool alias', True, default + export_entry + 't=0x01 d=0x7f040001\n' + alias_entry + true_value),
        ('cyclic alias', False, default + export_entry + 't=0x01 d=0x7f040000\n'),
        ('false override', False, default + export_entry + true_value + '      config v26:\n' + export_entry + false_value),
        ('no default', False, '      config v26:\n' + export_entry + true_value),
    ):
        resources.write_text(theme + export_spec + values)
        for contest in (False, True):
            make_apk(payload=not contest, mic=not contest)
            run(apk, resolved, f'APK {label}, contest={contest}', contest=contest,
                error=None if resolved else 'GameActivity not exported')
    resources.write_text(theme)

    (path / 'fixture.apk.xmltree').write_text(valid)
    make_apk(permission_tag='uses-permission-sdk-23')
    run(apk, True, 'SDK-23 APK permission satisfies requirement')
    make_apk(payload=False, permission_tag='uses-permission-sdk-23')
    run(apk, False, 'contest rejects SDK-23 APK permission', contest=True,
        error='contest build ships permission ' + permission)
    for payload, mic in ((True, False), (False, True), (True, True)):
        make_apk(payload=payload, mic=mic)
        run(apk, False, f'contest rejects configured payload={payload} permission={mic}', contest=True)
    make_apk(payload=False, mic=False, application_id=package + '.other')
    run(apk, False, 'contest retains exact package requirement', contest=True)
    make_apk(payload=False, mic=False)
    with zipfile.ZipFile(apk, 'a') as archive:
        archive.writestr(asset + '.other', 'synthetic unconfigured sibling')
        archive.writestr('assets/unconfigured.bin', 'synthetic unrelated asset')
    run(apk, True, 'contest excludes exact configured assets only', contest=True)

    (path / 'fixture.apk.xmltree').write_text(valid)
    make_apk(payload=False)
    run(apk, False, 'configured APK asset missing')
    make_apk(mic=False)
    run(apk, False, 'configured APK permission missing')
    make_apk(application_id=package + '.other')
    run(apk, False, 'configured package must match exactly')
    settings['quest']['launcherChecks'] = {'permissions': [], 'assets': []}
    config.write_text(json.dumps(settings))
    make_apk(payload=False, mic=False)
    run(apk, True, 'no implicit APK assets or permissions')
    make_apk()
    run(apk, True, 'contest empty checks impose no implicit payload ban', contest=True)
    make_apk(payload=False, mic=False)
    run(apk, False, 'missing config does not bypass APK guard', False)
    del settings['quest']['launcherChecks']
    config.write_text(json.dumps(settings))
    run(apk, True, 'launcherChecks omitted')
    make_apk()
    run(apk, True, 'contest launcherChecks omitted', contest=True)

    checks = settings['quest']['launcherChecks'] = {'assets': [{'glob': 'assets/synthetic-*.bin'}]}
    config.write_text(json.dumps(settings))
    run(apk, True, 'APK asset glob matches a file')
    run(apk, False, 'contest disallows any match for a configured glob', contest=True,
        error='contest build ships APK asset matching glob assets/synthetic-*.bin')
    make_apk(payload=False)
    with zipfile.ZipFile(apk, 'a') as archive:
        archive.writestr('assets/SYNTHETIC-payload.bin', 'different case')
        archive.writestr('assets/synthetic-dir.bin/', '')
    checks['assets'] = [{'glob': 'assets/synthetic-*'}]
    config.write_text(json.dumps(settings))
    run(apk, False, 'unmatched APK asset glob names the pattern',
        error='missing APK asset matching glob assets/synthetic-*')
    run(apk, True, 'contest allows an unmatched glob', contest=True)
    checks['assets'] = ['assets/synthetic-*.bin']
    config.write_text(json.dumps(settings))
    make_apk()
    run(apk, False, 'wildcard in string form stays literal', error='missing APK asset assets/synthetic-*.bin')
    with zipfile.ZipFile(apk, 'a') as archive:
        archive.writestr('assets/synthetic-*.bin', 'literal wildcard')
    run(apk, True, 'literal wildcard entry still satisfies an exact requirement')
    for invalid in ({'glob': '../assets/*'}, {'glob': '/assets/*'}, {'glob': 'assets/*', 'extra': True}, {'glob': None}):
        checks['assets'] = [invalid]
        config.write_text(json.dumps(settings))
        run(apk, False, f'reject invalid asset glob {invalid}', error='launcherChecks.assets')

assert not failures, 'Android launcher regressions:\n' + '\n'.join(failures)
print('android launcher synthetic source and APK checks passed')
PY
