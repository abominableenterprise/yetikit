#!/usr/bin/env python3
"""Check known Unity module API uses against each kit package's dependency closure."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "com.abominable.yetikit."
# Mask comments and ordinary literals while retaining line numbers. This is a
# lexical guard, not a C# parser (e.g. it doesn't inspect interpolation holes).
NON_CODE = re.compile(r'''//[^\n]*|/\*[\s\S]*?\*/|@"(?:""|[^"])*"|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*' ''', re.X)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def closure(name, edges):
    seen = {name}
    pending = list(edges[name])
    while pending:
        dep = pending.pop()
        if dep not in seen:
            seen.add(dep)
            pending.extend(edges.get(dep, ()))
    return seen - {name}


def lint(root):
    packages = sorted((root / "Packages").glob(f"{PREFIX}*/package.json"))
    if not packages:
        raise ValueError("no kit package manifests found")
    # Only follow reachable external packages, using their resolved dependency
    # metadata. Never use Host's root manifest or its stale kit lock entries.
    lock = read_json(root / "Host/Packages/packages-lock.json")["dependencies"]
    edges = {name: entry.get("dependencies", {}) for name, entry in lock.items()
             if not name.startswith(PREFIX)}
    for path in packages:
        edges[path.parent.name] = read_json(path).get("dependencies", {})
    module_apis = read_json(Path(__file__).with_name("unity-module-apis.json"))
    patterns = {f"com.unity.modules.{module}": re.compile(
        r"\b(?:" + "|".join(r"\s*\.\s*".join(map(re.escape, api.split("."))) for api in apis) + r")\b")
        for module, apis in module_apis.items()}
    failures = []
    for manifest in packages:
        package = manifest.parent
        declared = closure(package.name, edges)
        missing = patterns.keys() - declared
        for folder in ("Runtime", "Editor"):
            for path in sorted((package / folder).rglob("*.cs")):
                source = NON_CODE.sub(lambda m: re.sub(r"[^\n]", " ", m[0]), path.read_text(encoding="utf-8"))
                for module in sorted(missing):
                    if match := patterns[module].search(source):
                        line = source.count("\n", 0, match.start()) + 1
                        api = "".join(match[0].split())
                        failures.append(f"{path.relative_to(root)}:{line}: {api} requires {module} "
                                        f"(missing from {package.name} dependency closure)")
    return len(packages), failures


if __name__ == "__main__":
    try:
        count, errors = lint(ROOT)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.exit(f"[package-closure] {exc}")
    if errors:
        sys.exit("\n".join(errors))
    print(f"[package-closure] passed {count} kit packages")
