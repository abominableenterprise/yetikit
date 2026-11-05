"""Validate installable skill metadata; requires PyYAML."""

from pathlib import Path
import sys

import yaml


def validate_skill(path: Path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("missing opening frontmatter delimiter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise ValueError("missing closing frontmatter delimiter") from error
    metadata = yaml.safe_load("\n".join(lines[1:end]))
    if not isinstance(metadata, dict):
        raise ValueError("frontmatter must be a mapping")
    if metadata.get("name") != path.parent.name:
        raise ValueError("name must match the skill folder")
    description = metadata.get("description")
    if not isinstance(description, str) or not description.strip():
        raise ValueError("description must be a non-empty string")
    if len(lines) > 150:
        raise ValueError("skill exceeds 150 lines")


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    paths = sorted((root / "skills").glob("*/SKILL.md"))
    if not paths:
        print("ERROR: no skills found", file=sys.stderr)
        return 1
    failures = 0
    for path in paths:
        try:
            validate_skill(path)
        except (ValueError, yaml.YAMLError, OSError) as error:
            print(f"ERROR: {path.relative_to(root)}: {error}", file=sys.stderr)
            failures += 1
    print(f"Validated {len(paths)} skills; {failures} failures")
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
