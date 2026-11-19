"""Check the generated Starter files before copying them to the Host."""
import re
import sys
from pathlib import Path


GUID = re.compile(r"^guid: ([0-9a-fA-F]{32})$", re.MULTILINE)


def starter_guids(assets):
    starter = assets / "Starter"
    scripts = list(starter.rglob("*.cs"))
    if not scripts:
        raise ValueError(f"{starter}: no generated C# scripts")
    for source in [*scripts, *starter.rglob("*.asmdef")]:
        meta = source.with_name(source.name + ".meta")
        if not meta.is_file():
            raise ValueError(f"{source}: missing .meta")

    guids = {}
    for meta in [assets / "Starter.meta", *starter.rglob("*.meta")]:
        matches = GUID.findall(meta.read_text(encoding="utf-8"))
        if len(matches) != 1 or int(matches[0], 16) == 0:
            raise ValueError(f"{meta}: expected one nonzero 32-digit GUID")
        guid = matches[0].lower()
        if guid in guids:
            raise ValueError(f"{meta}: duplicates GUID from {guids[guid]}")
        guids[guid] = meta.relative_to(assets)
    return guids


def main(first, second):
    a, b = starter_guids(first), starter_guids(second)
    if set(a.values()) != set(b.values()):
        raise ValueError("Repeated generation produced different Starter metadata paths")
    shared = a.keys() & b.keys()
    if shared:
        path = a[min(shared)]
        raise ValueError(f"{path}: GUID reused across independent projects")
    print("Starter metadata GUIDs are valid, unique, and isolated across generations.")


if __name__ == "__main__":
    try:
        main(*map(Path, sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
