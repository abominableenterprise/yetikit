#!/usr/bin/env python3
"""Pin advertised kit packages and their local closure in a fresh consumer manifest."""

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
KIT = "com.abominable.yetikit."
BUILTIN = "com.unity.modules."


def advertised_packages(root):
    readme = (root / "README.md").read_text(encoding="utf-8")
    modules = readme.split("\n## Modules\n", 1)[1].split("\n## ", 1)[0]
    names = re.findall(r"\]\(Packages/(com\.abominable\.yetikit\.[a-z0-9.-]+)/README\.md\)", modules)
    if not names:
        raise ValueError("README Modules table advertises no kit packages")
    return names


def consumer_manifest(root, names):
    packages = root.resolve() / "Packages"
    dependencies = {}
    pending = list(names)
    while pending:
        name = pending.pop()
        if name in dependencies:
            continue
        path = packages / name
        package = json.loads((path / "package.json").read_text(encoding="utf-8"))
        if package["name"] != name:
            raise ValueError(f"Expected {name} in {path / 'package.json'}")
        dependencies[name] = f"file:{path}"
        for dep, version in package.get("dependencies", {}).items():
            if dep.startswith(KIT):
                pending.append(dep)
            elif dep.startswith(BUILTIN):
                if dependencies.setdefault(dep, version) != version:
                    raise ValueError(f"Conflicting declarations of {dep}")
        # UPM resolves the remaining registry and built-in transitive dependencies.
    return {"dependencies": dict(sorted(dependencies.items()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, default=ROOT)
    args = parser.parse_args()
    print(json.dumps(consumer_manifest(args.checkout, advertised_packages(args.checkout)), indent=2))


if __name__ == "__main__":
    main()
