#!/usr/bin/env python3
"""Verify that this starter has no local packages. Run again after Unity resolves it."""
import argparse
import json
from pathlib import Path
import re


KIT_PREFIX = "com.abominable.yetikit."
KIT_REMOTE = "https://github.com/abominableenterprise/yetikit.git"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[\w.-]+)?(?:\+[\w.-]+)?", re.ASCII)
REVISION = re.compile(r"[0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+(?:-[\w.-]+)?", re.ASCII)
REMOTE = re.compile(r"(?:git\+)?(?:https?|ssh)://[^/\s]+(?:/\S*)?|git://[^/\s]+/\S+")


def entries(path):
    deps = json.loads(path.read_text(encoding="utf-8"))["dependencies"]
    if not isinstance(deps, dict):
        raise ValueError(f"{path.name}: expected a dependencies object")
    return deps


def check_version(file, name, version):
    if not isinstance(version, str) or not (VERSION.fullmatch(version) or REMOTE.fullmatch(version)):
        raise ValueError(f"{file}: {name} must use a version or a remote URL, not a local path")


def verify(packages, manifest_only):
    for folder in packages.iterdir():
        if folder.is_dir() and (folder / "package.json").is_file():
            raise ValueError(f"Packages: {folder.name} is embedded")

    manifest = entries(packages / "manifest.json")
    revisions = set()
    for name, version in manifest.items():
        check_version("manifest.json", name, version)
        if name.startswith(KIT_PREFIX):
            prefix = f"{KIT_REMOTE}?path=/Packages/{name}#"
            if not version.startswith(prefix) or not REVISION.fullmatch(version[len(prefix):]):
                raise ValueError(f"manifest.json: {name} must pin the public kit Git remote by tag or commit")
            revisions.add(version[len(prefix):])
    if len(revisions) != 1:
        raise ValueError("manifest.json: expected kit packages at one shared revision")
    lock = packages / "packages-lock.json"
    if manifest_only and not lock.exists():
        return

    locked = entries(lock)
    for name, entry in locked.items():
        if not isinstance(entry, dict) or entry.get("source") not in {"git", "registry", "builtin"}:
            raise ValueError(f"{lock.name}: {name} must have a Git, registry or builtin source")
        check_version(lock.name, name, entry.get("version"))
        if "url" in entry and (not isinstance(entry["url"], str) or not REMOTE.fullmatch(entry["url"])):
            raise ValueError(f"{lock.name}: {name} must use a remote URL")
        for dep, version in entry.get("dependencies", {}).items():
            check_version(lock.name, dep, version)
        if name.startswith(KIT_PREFIX) and (entry["source"] != "git" or entry["version"] != manifest.get(name)):
            raise ValueError(f"{lock.name}: {name} must match its manifest Git pin")
    for name in manifest.keys() - locked.keys():
        raise ValueError(f"{lock.name}: missing {name}; resolve packages in Unity")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest-only", action="store_true", help="allow a missing lock before first import")
    args = parser.parse_args()
    try:
        verify(Path(__file__).resolve().parent / "Packages", args.manifest_only)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        parser.exit(1, f"Package verification failed: {error}\n")
    print("Starter package sources verified")


if __name__ == "__main__":
    main()
