#!/usr/bin/env python3
"""Validate committed and non-ignored Unity sources without an editor or licence."""
import json
from pathlib import Path
import re
import subprocess
import sys


def validate(root):
    listed = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    )
    paths = sorted({p.decode("utf-8") for p in listed.split(b"\0") if p})
    errors = []
    guids = {}
    for relative in paths:
        path = root / relative
        if not path.is_file():
            continue
        if relative.startswith("Packages/") and path.suffix == ".cs":
            if not Path(str(path) + ".meta").is_file():
                errors.append(f"{relative}: missing .cs.meta")
        if path.suffix == ".meta":
            matches = re.findall(r"^guid: ([0-9a-fA-F]{32})$", path.read_text(), re.M)
            if len(matches) != 1:
                errors.append(f"{relative}: expected one 32-digit GUID")
            else:
                guid = matches[0].lower()
                if guid in guids:
                    errors.append(f"{relative}: duplicate GUID with {guids[guid]}")
                guids[guid] = relative
        if path.suffix == ".asmdef":
            try:
                definition = json.loads(path.read_text())
                if not isinstance(definition, dict) or definition.get("autoReferenced") is not False:
                    errors.append(f"{relative}: autoReferenced must be false")
            except (ValueError, UnicodeError) as error:
                errors.append(f"{relative}: invalid JSON: {error}")
    return errors


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    failures = validate(root)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print("Unity metadata and assembly checks passed")
