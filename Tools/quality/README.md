# Mesh quality (no Unity seat)

Run static model checks before a consumer game imports or ships changed art:

```sh
python3 Tools/quality/mesh/check_meshes.py [--blender /path/to/blender] [--require-blender] [--config yetikit-quality.json] [--json out.json] model.glb model.fbx
```

Requires Python 3.10+ and numpy (`python3 -m pip install numpy`). GLB/glTF uses
an included reader; FBX uses headless Blender (4.1+ with its bundled numpy).
An absent Blender yields `SKIP … needs Blender` and exit 0 for FBX unless
`--require-blender` is set. An invalid explicit executable is also absent.
Missing/malformed/unsupported assets fail, rather than silently passing.
Exit 1 means at least one FAIL; invalid CLI/configuration exits 2. An empty file
list is a successful no-op. Each file gets one PASS/FAIL/SKIP line; JSON includes
per-mesh metrics, failures, thresholds and applied exception reasons.

## Checks and defaults

Threshold shares are fractions, not percentages; the text summary prints
percentages (maximum per-mesh share, summed topology counts). Each mesh must pass:

| Check | Default | Catches |
| --- | --- | --- |
| `inwardShare` | 0.01 (1%) | Triangles with at least 3 see-through ray votes and more through than front votes |
| `holeRayShare` | 0.01 (1%) | Back-first rays with no front-facing surface behind them, divided by all rays hitting geometry |
| `maxOpenEdges` | 0 | Missing faces and open boundaries |
| `maxOverEdges` | 0 | Edges shared by more than two faces |
| `maxSameWayEdges` | 0 | Neighbors using a shared edge in the same direction |

Whole inside-out closed components (negative signed volume) and zero-area
triangles always fail. The volume check is necessary: rays through an entirely
inverted closed cube can still see its far wall front-first. Exact position
welding joins UV/normal splits for topology only; it does not hide small cracks.
Ray sampling preserves the existing 64-direction Fibonacci sphere and 64×64
grid behavior. Rays behind another front face are not holes. A missing face can
be caught by topology even when ray votes alone miss it.

The Blender-only [winding](mesh/winding.py) and [watertight](mesh/watertight.py)
repair helpers are also available; their behavior is preserved, but the CLI
**only audits** and never repairs or overwrites assets. The
[headless driver](mesh/winding_audit.py) retains normal disagreement and level-view
ray diagnostics as additional report fields.

## Deliberate openings

Configuration is optional, explicitly selected, and validated before checking.
Paths match the CLI file paths normalized with `pathlib.Path`, relative to the
working directory, **not** to the configuration file. Every exception requires
a nonblank reason; unknown settings fail to prevent typo-based bypasses.

```json
{
  "thresholds": {
    "inwardShare": 0.01,
    "holeRayShare": 0.01,
    "maxOpenEdges": 0,
    "maxOverEdges": 0,
    "maxSameWayEdges": 0
  },
  "exceptions": {
    "Assets/Art/Tube.glb": {
      "allowOpen": true,
      "reason": "Intentional opening"
    }
  }
}
```

`allowOpen` waives open edges and both ray-share checks: an intentional opening
exposes inner walls to the same rays. It does **not** waive inconsistent or
over-used edges, degenerates, or wholly inverted closed components. Use narrow
per-asset exceptions and review their reasons alongside model changes.

## Changed-file CI

Run these recipes with **Bash** from the consumer repository root. The checkout
must include `origin/main` and enough history on both branches to find their
merge base. In GitHub Actions, use `actions/checkout` with `fetch-depth: 0`
(the default shallow checkout is insufficient), then fetch the base branch if
needed. `pipefail` makes selection errors fail the step rather than silently
passing an empty file list to the checker.

```sh
set -o pipefail
git diff --name-only origin/main... -- '*.glb' '*.fbx' | xargs python3 Tools/quality/mesh/check_meshes.py
```

For names containing whitespace, deleted assets, and deterministic CI Blender
availability, use the null-delimited variant:

```sh
set -o pipefail
git diff --name-only --diff-filter=ACMR -z origin/main... -- '*.glb' '*.gltf' '*.fbx' | xargs -0 -r python3 Tools/quality/mesh/check_meshes.py --require-blender --config yetikit-quality.json --json mesh-report.json
```

These commands assume the changed set fits one invocation; for very large sets,
use separate JSON output paths per batch to avoid overwriting reports.

## Scope and tests

Static mesh-local bind geometry is checked, including unused meshes; node
transforms, animation, skinning and morph deformation are not evaluated. Mesh
primitives within each glTF mesh are joined for topology; distinct meshes are
checked separately. Only glTF 2 uncompressed TRIANGLES, float positions and
unsigned indices are supported, including interleaved buffer views and
non-indexed primitives. Sparse/normalized accessors, required extensions and
compressed geometry fail clearly. Buffers must be embedded or local relative
files within the asset directory; no remote requests are made. Very large models
can be slow with the intentionally preserved Python ray rasterizer. These checks
are not proofs against self-intersection or every thin/sliver defect.

```sh
python3 Tools/quality/mesh/tests/fixtures/make_fixtures.py
python3 -m unittest discover -s Tools/quality/mesh/tests -v
```

The generator and tiny GLBs are committed: closed cube passes; a missing face,
two flipped faces and a fully inside-out cube fail; an open tube only passes with
its declared exception. Tests compare regenerated bytes, assert verdicts and
exercise reports, reader formats, topology seams and configuration errors.
Original repair regressions are retained; four integration tests skip without
Blender (`BLENDER=/path/to/blender` enables them), including a real FBX round trip
and a mirrored-transform lookalike. The
[quality workflow](../../.github/workflows/quality.yml) also runs the CLI over all
five fixtures, requiring the broken cases to return exactly exit 1.
