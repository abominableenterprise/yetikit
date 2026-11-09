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
activity = f'''    E: activity (line=5)
      A: android:theme(0x01010000)=@0x7f030001
      A: android:name(0x01010003)="{game}" (Raw: "{game}")
      A: android:exported(0x01010010)=(type 0x12)0xffffffff
'''
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
positives = {
    "valid": valid,
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

    def run(target, expected, label, configured=True, contest=False):
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
        if (result.returncode == 0) != expected:
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
    (path / 'fixture.apk.resources').write_text('spec resource 0x7f030001 com.example:style/BaseUnityGameActivityTheme: flags=0x00000000\n')

    def make_apk(*, payload=True, mic=True, application_id=package):
        badging = f"package: name='{application_id}'\nlaunchable-activity: name='{game}'\n"
        if mic:
            badging += f"uses-permission: name='{permission}'\n"
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
    (path / 'fixture.apk.xmltree').write_text(valid)
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

assert not failures, 'Android launcher regressions:\n' + '\n'.join(failures)
print('android launcher synthetic source and APK checks passed')
PY
