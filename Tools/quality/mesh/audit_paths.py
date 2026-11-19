"""Filesystem checks shared by the mesh reader and report writer."""
import errno


def resolve(path, *, strict=False):
    try:
        return path.resolve(strict=strict)
    except RuntimeError as exc:
        # Python 3.12 and earlier raise RuntimeError for symlink loops.
        raise OSError(errno.ELOOP, "symlink loop", str(path)) from exc


def _identity(path):
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    return info.st_dev, info.st_ino


def reject_report_alias(report, inputs):
    target = resolve(report)
    identity = _identity(target)
    for source in inputs:
        try:
            if resolve(source) == target or (identity is not None and _identity(source) == identity):
                raise ValueError(f"report path aliases an input: {source}")
        except OSError as exc:
            # A looping input has no file that could be overwritten. Its audit
            # failure still belongs in the report for the rest of the batch.
            if exc.errno not in (errno.ELOOP, errno.ENOTDIR):
                raise
