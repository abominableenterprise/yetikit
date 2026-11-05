#!/usr/bin/env python3
"""CI entry point for static mesh quality checks (no Unity required)."""
import argparse
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

from gltf_reader import load_meshes
from mesh_metrics import measure

DEFAULTS = {"inwardShare": 0.01, "holeRayShare": 0.01, "maxOpenEdges": 0,
            "maxOverEdges": 0, "maxSameWayEdges": 0}


def configuration(path):
    doc = json.loads(Path(path).read_text()) if path else {}
    if not isinstance(doc, dict) or set(doc) - {"thresholds", "exceptions"}:
        raise ValueError("config accepts only thresholds and exceptions")
    thresholds = dict(DEFAULTS)
    values = doc.get("thresholds", {})
    if not isinstance(values, dict) or set(values) - DEFAULTS.keys():
        raise ValueError("unknown thresholds")
    for key, value in values.items():
        limit = 1 if key.endswith("Share") else math.inf
        if (type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= limit
                or (not key.endswith("Share") and int(value) != value)):
            raise ValueError(f"invalid threshold: {key}")
    thresholds.update(values)
    exceptions = doc.get("exceptions", {})
    if not isinstance(exceptions, dict):
        raise ValueError("exceptions must be an object")
    for asset, rule in exceptions.items():
        if (not isinstance(rule, dict) or set(rule) - {"allowOpen", "reason"}
                or not isinstance(rule.get("reason"), str) or not rule["reason"].strip()
                or type(rule.get("allowOpen", False)) is not bool):
            raise ValueError(f"exception needs a reason and boolean allowOpen: {asset}")
    return thresholds, exceptions


def failures(row, thresholds, allow_open=False):
    checks = [("inward_share", "inwardShare"), ("hole_ray_share", "holeRayShare"),
              ("open_edges", "maxOpenEdges"), ("over_edges", "maxOverEdges"),
              ("same_way_edges", "maxSameWayEdges")]
    # An opening exposes legitimate inner walls to rays, so both opening-related
    # ray metrics are waived. Inconsistent edges and inside-out closed shells aren't.
    if allow_open:
        checks = checks[3:]
    bad = [metric for metric, threshold in checks if row[metric] > thresholds[threshold]]
    if row["inside_out"]:
        bad.append("inside_out")
    if row["degenerate"]:
        bad.append("degenerate")
    return bad


def check(path, thresholds, rule, blender, require_blender):
    row = {"file": path}
    try:
        suffix = Path(path).suffix.lower()
        if suffix not in (".glb", ".gltf", ".fbx"):
            raise ValueError("unsupported file type")
        if not Path(path).is_file():
            raise ValueError("file not found")
        if suffix == ".fbx":
            if not blender:
                row.update(status="FAIL" if require_blender else "SKIP", message="needs Blender")
                return row
            with tempfile.TemporaryDirectory() as temp:
                report = str(Path(temp) / "audit.json")
                result = subprocess.run([blender, "-b", "--factory-startup", "--python-exit-code", "1",
                                         "--python", str(Path(__file__).with_name("winding_audit.py")),
                                         "--", report, path], capture_output=True, text=True, timeout=300)
                if result.returncode:
                    raise ValueError("Blender audit failed: " + (result.stdout + result.stderr)[-1500:])
                meshes = json.loads(Path(report).read_text())
        else:
            meshes = [dict(measure(v, t), mesh=name) for name, v, t in load_meshes(path)]
        if not meshes:
            raise ValueError("no meshes")
        for mesh in meshes:
            mesh["failures"] = failures(mesh, thresholds, rule.get("allowOpen", False))
        row.update(status="FAIL" if any(m["failures"] for m in meshes) else "PASS", meshes=meshes)
        if rule:
            row["exception"] = rule
    except (ValueError, OSError, KeyError, IndexError, TypeError, AttributeError, OverflowError,
            struct.error, subprocess.SubprocessError) as exc:
        row.update(status="FAIL", message=str(exc))
    return row


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blender", help="Blender executable (otherwise searched on PATH)")
    parser.add_argument("--require-blender", action="store_true")
    parser.add_argument("--config", help="optional quality JSON; paths are relative to the working directory")
    parser.add_argument("--json", type=Path, help="write a machine-readable report")
    parser.add_argument("files", nargs="*", help=".glb, .gltf or .fbx files; empty list is a no-op")
    args = parser.parse_args(argv)
    try:
        thresholds, exceptions = configuration(args.config)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    exceptions = {Path(k).resolve(): v for k, v in exceptions.items()}
    blender = shutil.which(args.blender or "blender")
    rows = [check(path, thresholds, exceptions.get(Path(path).resolve(), {}), blender,
                  args.require_blender) for path in args.files]
    for row in rows:
        meshes = row.get("meshes", [])
        detail = (f"tris={sum(m['tris'] for m in meshes)} "
                  f"inward={max(m['inward_share'] for m in meshes):.2%} "
                  f"hole_rays={max(m['hole_ray_share'] for m in meshes):.2%} "
                  f"open={sum(m['open_edges'] for m in meshes)} "
                  f"over={sum(m['over_edges'] for m in meshes)} "
                  f"same_way={sum(m['same_way_edges'] for m in meshes)} "
                  f"checks={','.join(sorted({f for m in meshes for f in m['failures']})) or 'ok'}"
                  if meshes else row["message"])
        print(f"{row['status']} {row['file']}: {' '.join(detail.split())}")
    if args.json:
        args.json.write_text(json.dumps({"thresholds": thresholds, "files": rows}, indent=2) + "\n")
    return int(any(row["status"] == "FAIL" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
