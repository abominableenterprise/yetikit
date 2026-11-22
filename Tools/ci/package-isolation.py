#!/usr/bin/env python3
"""Compile kit packages in fresh Linux Unity projects without Host dependencies."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "com.abominable.yetikit."


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def local_packages(name):
    pending = [name]
    paths = {}
    while pending:
        dep = pending.pop()
        if dep in paths:
            continue
        path = ROOT / "Packages" / dep
        paths[dep] = path
        pending.extend(key for key in read_json(path / "package.json").get("dependencies", {})
                       if key.startswith(PREFIX))
    return paths


def compile_package(work, module):
    name = PREFIX + module
    project = work / module
    for folder in ("Assets", "Packages", "ProjectSettings"):
        (project / folder).mkdir(parents=True, exist_ok=False)
    paths = local_packages(name)
    write_json(project / "Packages/manifest.json", {
        "dependencies": {key: "file:" + str(path) for key, path in paths.items()},
    })
    for path in ("ProjectSettings/ProjectVersion.txt", "yetikit.json"):
        shutil.copyfile(ROOT / "Host" / path, project / path)
    env = {**os.environ, "PROJECT": str(project), "OUT_DIR": str(project / "build"),
           "TASK_CACHE": str(work / "disabled-task-cache")}
    print(f"[package-isolation] compiling {module} ({project}/build/open.log)", flush=True)
    if subprocess.run([ROOT / "Tools/ship/linux-unity.sh", "open"], env=env).returncode:
        return False
    # Verify assemblies actually compiled, not just that Unity opened. Skip only
    # asmdefs gated on an optional package absent from this project's resolution.
    resolved = read_json(project / "Packages/packages-lock.json")["dependencies"]
    expected = set()
    for path in paths.values():
        for folder in ("Runtime", "Editor"):
            for asmdef in (path / folder).rglob("*.asmdef"):
                info = read_json(asmdef)
                if any(rule["name"] not in resolved and rule["define"] in info.get("defineConstraints", [])
                       for rule in info.get("versionDefines", [])):
                    continue
                expected.add(info["name"])
    compiled = {path.stem for path in (project / "Library/ScriptAssemblies").glob("*.dll")}
    if not expected or expected - compiled:
        print(f"[package-isolation] {module}: missing compiled assemblies: {sorted(expected - compiled)}", flush=True)
        return False
    print(f"[package-isolation] passed {module}: {', '.join(sorted(expected))}", flush=True)
    return True


def main():
    modules = sorted(path.name.removeprefix(PREFIX) for path in (ROOT / "Packages").glob(PREFIX + "*"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modules", metavar="MODULE", nargs="*", help=f"all by default; choose from {', '.join(modules)}")
    args = parser.parse_args()
    if set(args.modules) - set(modules):
        parser.error(f"unknown module: {', '.join(sorted(set(args.modules) - set(modules)))}")
    work = Path(tempfile.mkdtemp(prefix="yetikit-package-isolation-"))
    print(f"[package-isolation] projects and logs: {work}", flush=True)
    failed = [module for module in dict.fromkeys(args.modules or modules) if not compile_package(work, module)]
    if failed:
        parser.exit(1, f"[package-isolation] failed: {', '.join(failed)}\n")


if __name__ == "__main__":
    main()
