"""Emit NUL-delimited mesh audit inputs for a committed Git diff."""
import argparse
import subprocess
import sys

GLTF = (b".gltf", b".glb")
MODELS = (*GLTF, b".fbx")


def git_paths(*args):
    return subprocess.run(["git", *args], stdout=subprocess.PIPE, check=True).stdout.split(b"\0")[:-1]


def select(base):
    # Treat renames as delete/add so moving a buffer away still triggers the audit.
    entries = iter(git_paths("diff", "--no-renames", "--name-status", "-z", f"{base}...HEAD", "--"))
    selected = set()
    buffer_changed = False
    for status, path in zip(entries, entries):
        lower = path.lower()
        if lower.endswith(b".bin"):
            buffer_changed = True
        if status != b"D" and lower.endswith(MODELS):
            selected.add(path)

    if buffer_changed:
        # Both text glTF and GLB can read external buffers. Audit all surviving
        # glTF-family assets rather than trying to infer ownership from names.
        selected.update(path for path in git_paths("ls-tree", "-r", "--name-only", "-z", "HEAD")
                        if path.lower().endswith(GLTF))
    return sorted(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", help="Git base ref (for example, origin/main)")
    args = parser.parse_args()
    try:
        paths = select(args.base)
    except subprocess.CalledProcessError as exc:
        return exc.returncode
    sys.stdout.buffer.write(b"".join(path + b"\0" for path in paths))
    return 0


if __name__ == "__main__":
    sys.exit(main())
