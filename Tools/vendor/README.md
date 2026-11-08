# Consumer vendoring and version pins

Run these tools from a YetiKit checkout against a consumer project. They need
Linux, Bash 4+, Git, jq, tar and GNU coreutils; no Unity or Python is needed.
The commands themselves stay in the kit checkout, outside the vendored Ship tree.

## Adopting / upgrading

```sh
/path/to/yetikit/Tools/vendor/kit-bump.sh v0.1.2 --project /path/to/consumer --modules core,quality
/path/to/yetikit/Tools/vendor/kit-check.sh --project /path/to/consumer
```

Version 0.1.2 releases core and quality; other module skeletons remain planned.
Without `--project`, both commands use the current directory. Existing kit modules are always retained
and repinned; `--modules` adds comma-separated module suffixes. Kit dependencies
are read recursively from the tagged package manifests, including cycles. Every
package in that closure gets an explicit Git URL at the same tag in the consumer
manifest. Non-kit dependencies and JSON key order are retained (jq reformats
whitespace). Dependencies must already be an object in the consumer manifest.

By default bump clones the public kit with `--depth 1 --branch <tag>` into a
cleaned-up temporary directory. For offline use:

```sh
/path/to/yetikit/Tools/vendor/kit-bump.sh v0.1.2 --project /path/to/consumer --modules core,quality --source /path/to/local/kit
```

`--source` must be a Git checkout containing that tag; it is read-only. The tag's
committed tree is used, **not** the current branch, index or dirty working tree.
The whole Ship directory is copied byte for byte, with executable bits preserved;
obsolete consumer files disappear. The only consumer write targets are
`Tools/yetikit/` and `Packages/manifest.json`. Linked destination paths and
symlinks/special files in Ship are rejected. Commit both changed targets together.
The summary reports old → new tag, full module names and the number of added,
removed or changed vendored files (including VERSION).

## VERSION receipt

The generated `Tools/yetikit/VERSION` has four ordered lines:

```text
tag=v0.1.2
commit=<40-character Git commit SHA>
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
