# Issue #19: Mesh quality follow-up audit

Baseline: [`main` at `8ab9195`](https://github.com/abominableenterprise/yetikit/commit/8ab919555a7e5af294ceb90c169df421323307c1). Reviewed the [issue body](https://github.com/abominableenterprise/yetikit/issues/19), all six comments (paginated API), and the source and tests from [PR #17](https://github.com/abominableenterprise/yetikit/pull/17). The tool lives in [`Tools/quality/mesh`](../../../Tools/quality/mesh).

## Already fixed on main

| Finding | Evidence |
| --- | --- |
| [Shard removal deletes an unrelated part](https://github.com/abominableenterprise/yetikit/issues/19#issuecomment-6656113385) | [`01e9471`](https://github.com/abominableenterprise/yetikit/commit/01e9471) in [PR #17](https://github.com/abominableenterprise/yetikit/pull/17) restricts removal to pieces incident to the split. [`test_small_independent_closed_part_survives_an_unrelated_split`](../../../Tools/quality/mesh/tests/test_watertight.py) adds a six-face cube apart from the split and asserts all triangles survive. The integration test was skipped locally (Blender unavailable). |
| [Changed-file recipes hide selection errors](https://github.com/abominableenterprise/yetikit/issues/19#issuecomment-6656114962) | [`01e9471`](https://github.com/abominableenterprise/yetikit/commit/01e9471) in [PR #17](https://github.com/abominableenterprise/yetikit/pull/17) enables Bash `pipefail` in both recipes and documents the required history. [`test_changed_file_ci.py`](../../../Tools/quality/mesh/tests/test_changed_file_ci.py) executes both recipes with a missing base ref, a missing merge base, and an auditor that fails. |

The primitive-index overflow that prompted the deferrals was already fixed by [`33db063`](https://github.com/abominableenterprise/yetikit/commit/33db063) in [PR #17](https://github.com/abominableenterprise/yetikit/pull/17); [`test_unsigned_indices_are_widened_before_offsets`](../../../Tools/quality/mesh/tests/test_gltf_reader.py) covers both 8-bit and 16-bit indices.

## Open on main, fixed by this follow-up

Each repro below failed before the fix and is covered in [`test_audit_regressions.py`](../../../Tools/quality/mesh/tests/test_audit_regressions.py).

| Finding | Baseline repro and new expectation |
| --- | --- |
| [Duplicate GLB JSON chunks](https://github.com/abominableenterprise/yetikit/issues/19#issuecomment-6656109161) | Put the missing-face JSON first and closed-cube JSON second, then add the closed cube's BIN. The baseline passes the cube. Reject duplicate and out-of-order JSON/BIN chunks; still ignore unknown chunks in valid positions. |
| [Buffer/accessor alignment](https://github.com/abominableenterprise/yetikit/issues/19#issuecomment-6656110570) | Prefix the binary payload with one byte and shift both views; the gate passes. Also reproduced unaligned relative accessor offsets, a 13-byte position stride, and an explicit index stride. Reject those without requiring 4-byte alignment for tightly packed 16-bit index views. |
| [Report/input path collision](https://github.com/abominableenterprise/yetikit/pull/17#discussion_r4479199152) | Use the audited cube or its external buffer as `--json`, directly or via a symlink or hard link. The report overwrites the input even after a failed audit. Reject all these aliases and preserve source bytes. The [review regression](https://github.com/abominableenterprise/yetikit/pull/200#discussion_r4622771700) also verifies protection when an unsupported version, a required extension, or a missing earlier buffer stops loading before the referenced buffer is read. |
| [Looping buffer symlink](https://github.com/abominableenterprise/yetikit/pull/17#discussion_r4479199163) | Reference a self-referential symlink from a split glTF, then audit a second asset. The baseline raises `RuntimeError` on Python 3.11 instead of finishing the batch. Now both looping buffer and looping asset paths produce FAIL rows, the later cube passes, and the report is written. |
| [Optional material variants](https://github.com/abominableenterprise/yetikit/issues/19#issuecomment-6656111926) | Attach optional `KHR_materials_variants` to a closed cube. The baseline rejects the primitive; the same geometry now passes. Required extensions and unsupported primitive extensions still fail. |
| [High-multiplicity connectivity](https://github.com/abominableenterprise/yetikit/pull/17#discussion_r4479199169) | Give 1,024 triangles one shared edge and stub ray voting to isolate topology. The baseline peaks above 32 MiB in traced allocations. Linear adjacency stays under the regression's 12 MiB ceiling and retains the over-used/open edge counts. |

## Still open

| Finding | Repro and remaining work |
| --- | --- |
| [Nested cavity shell winding](https://github.com/abominableenterprise/yetikit/pull/17#discussion_r4479199174) | Combine the unit-cube fixture with a concentric half-scale cube whose triangles are reversed. `measure()` reports `inside_out=12` even though the enclosed cavity has correct winding and the mesh has no open, over-used, or same-way edges. [`wind_outward()`](../../../Tools/quality/mesh/watertight.py) also treats every negative-volume island as inverted (repair path inspected, not run). Containment and alternating winding are a separate geometric change. |
| [Repair without UVs](https://github.com/abominableenterprise/yetikit/pull/17#discussion_r4479199184) | Blender repro recipe: remove one side of a cube with no UV layer, then call [`close_holes()`](../../../Tools/quality/mesh/watertight.py). The fill path indexes loop UVs with `uv_layer=None` instead of skipping UV work. Not executed here: Blender unavailable. |
| [Repair that removes every face](https://github.com/abominableenterprise/yetikit/pull/17#discussion_r4479199190) | Blender repro recipe: pass a single triangle or an open triangulated plane grid to [`close_holes()`](../../../Tools/quality/mesh/watertight.py). Repeated fin removal can erase all faces before `bm.to_mesh`; [`unclosed()`](../../../Tools/quality/mesh/watertight.py) accepts the resulting zero-edge report. Preserve the original mesh on empty repair and refuse empty output. The read-only auditor already rejects empty triangle meshes. Not executed here: Blender unavailable. |
| [External-buffer-only CI changes](https://github.com/abominableenterprise/yetikit/issues/19#issuecomment-6656116192) | Commit `cube.gltf` and its external `cube.bin`, then change only the buffer. A synthetic two-commit diff confirmed that the documented model filters select no files. Direct auditing still reads the buffer; the recipes need dependency-aware selection or a conservative fallback. Until then, explicitly audit owning `.gltf` assets on external buffer changes. |
