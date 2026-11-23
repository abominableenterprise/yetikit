# Consumer vendoring and version pins

Run these tools from a YetiKit checkout against a consumer project. They need
Linux, Bash 4+, Git, jq, util-linux (`flock`) and GNU coreutils; no Unity or Python is needed.
The commands themselves stay in the kit checkout, outside the vendored Ship tree.
The offline developer test suite also runs the package dependency linter and needs Python 3.

## Adopting / upgrading

```sh
/path/to/yetikit/Tools/vendor/kit-bump.sh v0.3.5 --project /path/to/consumer --modules core,quality
/path/to/yetikit/Tools/vendor/kit-check.sh --project /path/to/consumer
```

Without `--project`, both commands use the current directory. Existing kit modules
are always retained and repinned; `--modules` adds comma-separated module suffixes.
Version 0.3.5 supports `core`, `quality`, `hands`, `interaction`, `playtest`,
`playtest.xr` and `lab`; playtest, playtest.xr and lab are development-only.
Kit dependencies are read recursively from the tagged package manifests, including cycles. Every
package in that closure gets an explicit Git URL at the same tag in the consumer
manifest. Non-kit dependencies and JSON key order are retained (jq reformats
whitespace). Dependencies must already be an object in the consumer manifest.

By default bump shallow-fetches the exact public kit tag ref, even if a branch
has the same name. For offline use:

```sh
/path/to/yetikit/Tools/vendor/kit-bump.sh v0.3.5 --project /path/to/consumer --modules core,quality --source /path/to/local/kit
```

`--source` must be a Git checkout containing that tag; it is read-only. The tag's
committed tree is used, **not** the current branch, index or dirty working tree.
Ship is read from raw Git blobs, ignoring archive attributes and checkout filters,
with executable bits preserved. Obsolete consumer files disappear. Bump rejects
linked destination paths and symlinks/special files in Ship. It locks the project
before reading its manifest and rejects an overlapping bump. Replacements are
staged beside each destination; if installation fails before the manifest rename,
bump restores the previous Ship tree. This is rollback on error, not an atomic
snapshot for concurrent readers or recovery from a system crash. Commit the two
outputs (`Tools/yetikit/` and `Packages/manifest.json`) together.
The summary reports old → new tag, full module names and the number of added,
removed or changed vendored files (including VERSION).

## VERSION receipt

The generated `Tools/yetikit/VERSION` has four ordered lines:

```text
tag=v0.3.5
commit=<40-character SHA-1 or 64-character SHA-256 Git commit ID>
sha256=<64-character SHA-256 tree digest>
dependencies=<compact JSON object of full kit package names to direct kit dependency arrays>
```

The first three fields identify the source and Ship payload. The fourth records
the selected dependency graph, so CI can verify closure **offline**, without
Unity's package cache or a second network fetch. Do not edit this receipt either;
rerun bump to change the selection. Removing a recorded module requires a fresh
bump after removing its manifest pin (unless another module still needs it).

Both commands share `common.sh`'s `tree_hash` function. Files are sorted by relative
path in the C locale. Each record is relative path, NUL, executable bit (`0`/`1`),
NUL, decimal byte length, NUL, then the exact file bytes. Only the root `VERSION`
is excluded; nested files named VERSION are hashed. Empty directories, timestamps
and non-executable permission bits do not affect the digest. The receipt detects
accidental changes, not malicious edits to both the payload and receipt; review
and trust the kit tag and committed consumer changes.

## Consumer CI rules

```sh
/path/to/yetikit/Tools/vendor/kit-check.sh --project /path/to/consumer
```

The check exits 1 with a repair message for a changed bundle, missing/invalid
receipt, inconsistent Git pin or missing dependency. Fix upstream, then kit-bump;
never patch vendored Ship or package code directly in a consumer game. A `file:`
kit pin fails unless `YETIKIT_ALLOW_FILE=1` is explicitly set for local debugging.
That override permits only file pins; it does not bypass digest or closure checks.
Keep it unset in CI. All non-file kit pins must match the canonical public Git
URL, package path and receipt tag exactly.

## Offline regression suite

```sh
Tools/vendor/tests/run.sh
```

Tests create synthetic consumer/source repositories and tags in temporary storage.
They do not clone from the network or require Unity. The [vendor workflow](../../.github/workflows/vendor.yml)
runs the same suite on Ubuntu 24.04.
