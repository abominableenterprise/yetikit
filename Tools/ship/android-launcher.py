#!/usr/bin/env python3
"""Check Unity's Quest GameActivity contract and optional consumer requirements.

Usage: android-launcher.py --config /absolute/path/yetikit.json manifest.xml|app.apk
Permissions and APK asset entries are required only when configured under
quest.launcherChecks. There are no game-specific defaults.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ANDROID = "{http://schemas.android.com/apk/res/android}"
GAME = "com.unity3d.player.UnityPlayerGameActivity"
THEME = "@style/BaseUnityGameActivityTheme"
VR = "com.oculus.intent.category.VR"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def configuration(path):
    with open(path, encoding="utf-8") as stream:
        config = json.load(stream)
    require(isinstance(config, dict), "config must be an object")
    quest = config.get("quest")
    require(isinstance(quest, dict), "missing quest config block")
    package = quest.get("package")
    require(isinstance(package, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+", package),
            "missing or invalid quest.package")
    checks = quest.get("launcherChecks", {})
    require(isinstance(checks, dict), "quest.launcherChecks must be an object")
    require(checks.get("package", package) == package, "launcherChecks.package must match quest.package")
    for key in ("permissions", "assets"):
        values = checks.get(key, [])
        require(isinstance(values, list) and all(isinstance(value, str) and value
                and not re.search(r"[\x00-\x1f]", value) for value in values),
                "launcherChecks." + key + " must be a string array")
    for asset in checks.get("assets", []):
        require(not asset.startswith("/") and ".." not in asset.split("/") and asset != ".",
                "launcherChecks.assets must contain relative APK entry paths")
    return package, checks


def game_contract(activity):
    """Check direct children, never entries from another activity or filter."""
    require(any(m.get(ANDROID + "name") == "android.app.lib_name" and m.get(ANDROID + "value") == "game"
                for m in activity.findall("meta-data")), "missing Unity game library metadata")
    require(any({a.get(ANDROID + "name") for a in f.findall("action")} >= {"android.intent.action.MAIN"}
                and {c.get(ANDROID + "name") for c in f.findall("category")}
                >= {"android.intent.category.LAUNCHER", VR}
                for f in activity.findall("intent-filter")), "missing Quest VR MAIN/LAUNCHER filter")


def decoded_manifest(tree):
    """Reconstruct aapt dump xmltree's hierarchy, preserving resource references."""
    document = ET.Element("document")
    stack = [(-1, document)]
    for line in tree.splitlines():
        indent = len(line) - len(line.lstrip())
        element = re.match(r"\s*E: ([\w.-]+) \(line=\d+\)", line)
        if element:
            while stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, ET.SubElement(stack[-1][1], element.group(1))))
            continue
        attribute = re.match(r'\s*A: android:([\w_]+)(?:\(0x[0-9a-fA-F]+\))?='
                             r'(?:"([^"]*)"|(@0x[0-9a-fA-F]+))', line)
        if attribute and indent > stack[-1][0]:
            stack[-1][1].set(ANDROID + attribute.group(1),
                             attribute.group(2) if attribute.group(2) is not None else attribute.group(3))
    root = document.find("manifest")
    require(root is not None, "missing decoded APK manifest")
    return root


def payload_check(present, contest, what):
    require(not present if contest else present,
            ("contest build ships " if contest else "missing ") + what)


def source(path, package, checks, contest=False):
    root = ET.parse(path).getroot()
    # Unity source manifests may omit package; the build then supplies the ID.
    require(root.get("package", package) == package, "wrong application ID")
    permissions = {p.get(ANDROID + "name") for p in root.findall("uses-permission")}
    for permission in checks.get("permissions", []):
        payload_check(permission in permissions, contest, "permission " + permission)
    activities = root.findall("./application/activity")
    require(len(activities) == 1 and activities[0].get(ANDROID + "name") == GAME,
            "expected only UnityPlayerGameActivity")
    activity = activities[0]
    require(activity.get(ANDROID + "theme") == THEME, "missing Unity GameActivity theme")
    require(activity.get(ANDROID + "exported") == "true", "GameActivity not exported")
    game_contract(activity)
    print("Manifest: Quest launcher and Unity theme OK (asset requirements are checked in APKs)")


def aapt_path():
    override = os.environ.get("AAPT")
    if override:
        return override
    sdk = os.environ.get("ANDROID_SDK_ROOT")
    require(sdk, "set ANDROID_SDK_ROOT or AAPT")
    tools = Path(sdk) / "build-tools"
    versions = [p for p in tools.iterdir() if p.is_dir() and (p / "aapt").is_file()]
    require(versions, "no aapt in SDK build-tools")
    # Numeric version ordering, without tying consumers to one SDK version.
    def version(path):
        return tuple(int(n) for n in re.findall(r"\d+", path.name)), path.name
    return str(max(versions, key=version) / "aapt")


def apk(path, package, checks, contest=False):
    tools = aapt_path()
    badging = subprocess.check_output([tools, "dump", "badging", path], text=True)
    tree = subprocess.check_output([tools, "dump", "xmltree", path, "AndroidManifest.xml"], text=True)
    require(re.search(r"^package: name='" + re.escape(package) + "'", badging, re.M), "wrong application ID")
    for permission in checks.get("permissions", []):
        payload_check(re.search(r"^uses-permission: name='" + re.escape(permission) + "'", badging, re.M),
                      contest, "permission " + permission)
    require(re.search(r"^launchable-activity: name='" + re.escape(GAME) + r"'", badging, re.M),
            "GameActivity not launchable")
    root = decoded_manifest(tree)
    activities = [a for a in root.findall("./application/activity") if a.get(ANDROID + "name") == GAME]
    require(len(activities) == 1, "expected one UnityPlayerGameActivity in merged manifest")
    activity = activities[0]
    game_contract(activity)
    # AAPT resolves theme references to resource IDs; inspect the resource table's style name.
    resources = subprocess.check_output([tools, "dump", "resources", path], text=True)
    match = re.search(r"(?:spec )?resource (0x[0-9a-fA-F]+) .*:style/BaseUnityGameActivityTheme:", resources)
    require(match, "missing Unity GameActivity theme resource")
    require(activity.get(ANDROID + "theme", "").lower() == "@" + match.group(1).lower(),
            "GameActivity does not use Unity GameActivity theme")
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "corrupt APK zip entry")
        names = set(archive.namelist())
        for asset in checks.get("assets", []):
            payload_check(asset in names, contest, "APK asset " + asset)
    print("APK: Quest launcher, Unity theme, configured permissions/assets and ZIP integrity OK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="consumer yetikit.json")
    parser.add_argument("--contest", action="store_true",
                        help="require configured development permissions/assets to be absent")
    parser.add_argument("path", help="source manifest or APK")
    args = parser.parse_args()
    try:
        expected_package, required_checks = configuration(args.config)
        (apk if args.path.endswith(".apk") else source)(args.path, expected_package, required_checks, args.contest)
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError, zipfile.BadZipFile,
            RuntimeError, NotImplementedError) as error:
        sys.exit(f"Android launcher check failed: {error}")
