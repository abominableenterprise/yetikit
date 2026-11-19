#!/usr/bin/env python3
"""Generate a game-owned Unity project without opening Unity or touching an existing project."""
import argparse
import json
import math
from pathlib import Path
import re
import shutil
import struct
import uuid
import wave


TEMPLATE = Path(__file__).resolve().parent
HOST = TEMPLATE.parents[1] / "Host"
KIT_URL = "https://github.com/abominableenterprise/yetikit.git"
# All kit modules resolve to the same revision until the starter APIs are tagged.
KIT_REVISION = "0829f97d461466eee5381f3f05ca3d99c6ffe77b"
PLACEHOLDERS = {"changeme", "default", "placeholder", "replace", "template", "todo", "yourcompany", "yourgame"}


def placeholder(value):
    words = re.findall(r"[a-z0-9]+", value.lower())
    return bool(PLACEHOLDERS.intersection(words)) or "".join(words) in PLACEHOLDERS


def impact_sound(path):
    rate = 22050
    count = rate // 12
    samples = (int(13000 * math.sin(2 * math.pi * 620 * i / rate) * (1 - i / count) ** 3)
               for i in range(count))
    with wave.open(str(path), "wb") as wav:
        wav.setparams((1, 2, rate, count, "NONE", "not compressed"))
        wav.writeframes(struct.pack(f"<{count}h", *samples))


def generate(out, app_id, title):
    for name in ("AGENTS.md", ".checknorris.md", "README.md"):
        text = (TEMPLATE / name).read_text(encoding="utf-8")
        (out / name).write_text(text.replace("{{GAME_NAME}}", title).replace("{{GAME_ID}}", app_id), encoding="utf-8")
    shutil.copyfile(TEMPLATE / "verify-packages.py", out / "verify-packages.py")
    for folder in ("docs", "routines", "Assets"):
        shutil.copytree(TEMPLATE / folder, out / folder)
    shutil.copyfile(TEMPLATE / "gitignore.txt", out / ".gitignore")
    shutil.copyfile(TEMPLATE.parents[1] / "LICENSE", out / "LICENSE")

    settings = out / "ProjectSettings"
    settings.mkdir()
    shutil.copyfile(HOST / "ProjectSettings/ProjectVersion.txt", settings / "ProjectVersion.txt")
    player = (HOST / "ProjectSettings/ProjectSettings.asset").read_text(encoding="utf-8")
    changes = {
        "productGUID": uuid.uuid4().hex,
        "activeInputHandler": "1",
        "productName": json.dumps(title),
        "overrideDefaultApplicationIdentifier": "1",
        "metroPackageName": app_id,
        "metroApplicationDescription": json.dumps(title),
        "applicationIdentifier": f"\n    Android: {app_id}\n    Standalone: {app_id}\n    iPhone: {app_id}",
    }
    for key, value in changes.items():
        separator = "" if value.startswith("\n") else " "
        player, count = re.subn(rf"(?m)^  {key}: [^\n]*$", lambda _: f"  {key}:{separator}{value}", player)
        if count != 1:
            raise ValueError(f"Expected one default for {key}")
    (settings / "ProjectSettings.asset").write_text(player, encoding="utf-8")

    packages = out / "Packages"
    packages.mkdir()
    deps = json.loads((HOST / "Packages/manifest.json").read_text(encoding="utf-8"))["dependencies"]
    for name in deps:
        if name.startswith("com.abominable.yetikit."):
            deps[name] = f"{KIT_URL}?path=/Packages/{name}#{KIT_REVISION}"
    deps["com.unity.modules.audio"] = "1.0.0"
    (packages / "manifest.json").write_text(json.dumps({"dependencies": deps}, indent=2) + "\n", encoding="utf-8")

    assets = out / "Assets"
    impact_sound(assets / "Starter/Impact.wav")
    for asset in sorted(assets.rglob("*")):
        if asset.suffix == ".meta":
            continue
        folder = "folderAsset: yes\n" if asset.is_dir() else ""
        Path(f"{asset}.meta").write_text(f"fileFormatVersion: 2\nguid: {uuid.uuid4().hex}\n{folder}", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True, help="consumer-owned reverse-DNS application ID")
    parser.add_argument("--title", required=True)
    parser.add_argument("--out", required=True, type=Path, help="new project directory (must not exist)")
    args = parser.parse_args()
    app_id, title = args.id, args.title.strip()
    if (not re.fullmatch(r"[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*){2,}", app_id)
            or any(placeholder(part) for part in app_id.split("."))
            or app_id.startswith(("com.example.", "org.example.", "net.example.", "com.company.", "com.unity."))):
        parser.error("--id must be a non-placeholder reverse-DNS application ID")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 .,'&!()_-]{0,79}", title) or placeholder(title) or title.lower() in {
            "game", "new game", "my game", "untitled", "untitled game"}:
        parser.error("--title must be a non-placeholder title (1–80 supported characters)")
    try:
        args.out.mkdir()
    except OSError as error:
        parser.error(str(error))
    try:
        generate(args.out, app_id, title)
    except Exception:
        shutil.rmtree(args.out)
        raise
    print(f"Created {args.out}")


if __name__ == "__main__":
    main()
