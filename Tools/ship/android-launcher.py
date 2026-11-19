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
from fnmatch import fnmatchcase
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
    permissions = checks.get("permissions", [])
    require(isinstance(permissions, list) and all(config_string(value) for value in permissions),
            "launcherChecks.permissions must be a string array")
    assets = checks.get("assets", [])
    require(isinstance(assets, list) and all(asset_requirement(asset) for asset in assets),
            'launcherChecks.assets must be an array of relative APK entry paths or {"glob": "pattern"} objects')
    return package, checks


def config_string(value):
    return isinstance(value, str) and bool(value) and not re.search(r"[\x00-\x1f]", value)


def asset_requirement(asset):
    if isinstance(asset, dict) and asset.keys() == {"glob"}:
        asset = asset["glob"]
    return (config_string(asset) and not asset.startswith("/")
            and ".." not in asset.split("/") and asset != ".")


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
                             r'(?:"([^"]*)"|(@0x[0-9a-fA-F]+)|\(type 0x12\)(0x[0-9a-fA-F]+)(?=\s|$))', line)
        if attribute and indent > stack[-1][0]:
            name, text, resource, boolean = attribute.groups()
            if boolean is not None:
                text = "true" if int(boolean, 16) else "false"
            stack[-1][1].set(ANDROID + name, text if text is not None else resource)
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
    permissions = {p.get(ANDROID + "name") for p in root
                   if p.tag in ("uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m")}
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


# Qualifiers with unambiguous equality or minimum matching in aapt's config names.
# Leave special cases (such as locale and density) opaque rather than guessing
# about their compatibility or ranking on a device.
MIN_QUALIFIER = re.compile(r"(?:(sw|w|h)(\d+)dp|(v)(\d+))")
EXACT_AXES = (
    ("ldltr", "ldrtl"), ("notlong", "long"), ("notround", "round"),
    ("nowidecg", "widecg"), ("lowdr", "highdr"), ("port", "land", "square"),
    ("desk", "television", "appliance", "watch", "vrheadset"),
    ("notnight", "night"), ("notouch", "finger", "stylus"), ("nokeys", "qwerty", "12key"),
    ("navexposed", "navhidden"), ("nonav", "dpad", "trackball", "wheel"),
)
AXIS = {qualifier: axis[0] for axis in EXACT_AXES for qualifier in axis}
# Earlier Android qualifier groups take priority. Keep width and height as
# separate constraints because their combined ranking depends on the request.
QUALIFIER_ORDER = (
    "mcc", "mnc", "ldltr", "sw", "w", "h", "notlong", "notround", "nowidecg",
    "lowdr", "port", "desk", "notnight", "notouch", "nokeys", "navexposed", "nonav", "v",

)


def resource_config(name):
    exact, minimum, opaque = {}, {}, set()
    if name != "(default)":
        for qualifier in name.split("-"):
            match = MIN_QUALIFIER.fullmatch(qualifier)
            if match:
                minimum[match[1] or match[3]] = int(match[2] or match[4])
            elif qualifier in AXIS:
                exact[AXIS[qualifier]] = qualifier
            elif re.fullmatch(r"m[cn]c\d+", qualifier):
                exact[qualifier[:3]] = qualifier
            else:
                opaque.add(qualifier)
    return exact, minimum, opaque


def config_implies(required, candidate):
    """Whether an always-matching candidate is guaranteed by these constraints."""
    return (candidate[0].items() <= required[0].items()
            and all(required[1].get(axis, 0) >= n for axis, n in candidate[1].items())
            and candidate[2] <= required[2])


def config_rank(config):
    exact, minimum, _ = config
    return tuple(minimum.get(axis, axis in exact) for axis in QUALIFIER_ORDER)


def outranks(left, right):
    if left > right:
        first = next(axis for axis, a, b in zip(QUALIFIER_ORDER, left, right) if a != b)
        height = QUALIFIER_ORDER.index("h")
        return first != "w" or left[height] >= right[height]
    return False


def apk_exported(value, resources):
    if value == "true":
        return True
    if not value or not re.fullmatch(r"@0x[0-9a-fA-F]+", value):
        return False

    entries, configs, ranks = {}, {}, {}
    config = None
    for line in resources.splitlines():
        line = line.strip()
        if line.startswith(("Package ", "type ", "config ")):
            header = re.fullmatch(r"config (\S+?)(?: flags=0x[0-9a-fA-F]+(?: \[\w+\])*)?:", line)
            config = header[1] if header else None
        entry = re.fullmatch(r"resource (0x[0-9a-fA-F]+) \S+: (.*)", line)
        if entry and config is not None:
            resource = int(entry[1], 16)
            entries.setdefault(resource, {}).setdefault(config, set()).add(entry[2])
            if config not in configs:
                configs[config] = resource_config(config)
                ranks[config] = config_rank(configs[config])

    # Only discard candidates we can prove lose: a better-ranked override
    # must match throughout this context, with identical opaque qualifiers.
    # Keep potentially reachable values when precedence is unclear.
    def shadowed(resource, selected, context):
        return any(configs[other][2] == configs[selected][2] and outranks(ranks[other], ranks[selected])
                   and config_implies(context, configs[other]) for other in entries[resource])

    def is_true(resource, context, path):
        # An unconditional default is required at the root. An alias target
        # can omit it if a variant matches throughout the context that needs it.
        # Carry the intersection along the path, including through defaults.
        variants = entries.get(resource, {})
        if not any(config_implies(context, configs[name]) for name in variants):
            return False
        exact, minimum, opaque = context
        for name, values in variants.items():
            other_exact, other_minimum, other_opaque = configs[name]
            if any(axis in exact and exact[axis] != token for axis, token in other_exact.items()):
                continue
            combined = (exact | other_exact,
                        minimum | {axis: max(n, minimum.get(axis, 0)) for axis, n in other_minimum.items()},
                        opaque | other_opaque)
            if (shadowed(resource, name, combined)
                    or any(shadowed(prior, selected, combined) for prior, selected in path)):
                continue
            if any(prior == resource for prior, _ in path):
                return False
            for entry in values:
                typed = re.match(r"t=(0x[0-9a-fA-F]+) d=(0x[0-9a-fA-F]+)(?=\s|$)", entry)
                if not typed:
                    return False
                kind, data = (int(field, 16) for field in typed.groups())
                if not ((kind == 0x12 and data != 0)
                        or (kind == 0x01 and is_true(data, combined, (*path, (resource, name))))):
                    return False
        return True

    return is_true(int(value[1:], 16), resource_config("(default)"), ())


def apk(path, package, checks, contest=False):
    tools = aapt_path()
    badging = subprocess.check_output([tools, "dump", "badging", path], text=True)
    tree = subprocess.check_output([tools, "dump", "xmltree", path, "AndroidManifest.xml"], text=True)
    require(re.search(r"^package: name='" + re.escape(package) + "'", badging, re.M), "wrong application ID")
    for permission in checks.get("permissions", []):
        present = re.search(r"^uses-permission(?:-sdk-23)?: name='" + re.escape(permission) + "'", badging, re.M)
        payload_check(present, contest, "permission " + permission)
    require(re.search(r"^launchable-activity: name='" + re.escape(GAME) + r"'", badging, re.M),
            "GameActivity not launchable")
    root = decoded_manifest(tree)
    activities = [a for a in root.findall("./application/activity") if a.get(ANDROID + "name") == GAME]
    require(len(activities) == 1, "expected one UnityPlayerGameActivity in merged manifest")
    activity = activities[0]
    resources = subprocess.check_output([tools, "dump", "resources", path], text=True)
    require(apk_exported(activity.get(ANDROID + "exported"), resources), "GameActivity not exported")
    game_contract(activity)
    # AAPT resolves theme references to resource IDs; inspect the resource table's style name.
    match = re.search(r"(?:spec )?resource (0x[0-9a-fA-F]+) .*:style/BaseUnityGameActivityTheme:", resources)
    require(match, "missing Unity GameActivity theme resource")
    require(activity.get(ANDROID + "theme", "").lower() == "@" + match.group(1).lower(),
            "GameActivity does not use Unity GameActivity theme")
    with zipfile.ZipFile(path) as archive:
        require(archive.testzip() is None, "corrupt APK zip entry")
        names = set(archive.namelist())
        for asset in checks.get("assets", []):
            if isinstance(asset, str):
                payload_check(asset in names, contest, "APK asset " + asset)
            else:
                pattern = asset["glob"]
                present = any(not name.endswith("/") and fnmatchcase(name, pattern) for name in names)
                payload_check(present, contest, "APK asset matching glob " + pattern)
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
