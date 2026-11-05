---
name: yetikit-asset-intake
description: Take a concept image through modeling, conversion and visual mesh checks; use before importing and placing a new generated or authored asset.
---
# Asset intake

Kit mesh validators are **(planned API, see [docs/design.md](../../docs/design.md))**.
Use the game's available art tooling; missing checks are a gap to report, not
an invented successful command.

1. Start with an approved concept image and record intended scale, forward,
   ground point, grip and triangle/texture budget. Check source rights; use no
   private photos or recordings as public fixtures.
2. Choose a generator for a suitable standalone model, or Blender for precise
   geometry, cleanup, topology or rigging. Judge the result against the concept,
   not just a generator's preview. Keep raw sources in the game's staging area.
3. Model, then convert GLB→FBX with the game's supported converter. Preserve
   scale, axes, materials and rig; compare before/after bounds and orientation.
   Do not hand-fix an imported mesh without updating its reproducible source.
4. Run mesh checks before import: winding/outside rays, holes/watertightness,
   non-finite vertices, degenerates and negative scale. Declare intentional
   openings such as an open tube. Include valid and broken synthetic fixtures
   when introducing a validator; do not disable checks to accept an asset.
5. Import using the existing game pipeline, with the intended rig type for
   characters. Validate materials, normals, colliders and budget in Unity.
6. Render **front, back and below** with neutral lighting. Inspect the underside,
   **wrists, neck and mouth** for holes, inverted faces and seams; orbit around
   joints and test deformation if rigged. A good front render is insufficient.
   Fix at source, reconvert and repeat checks after any repair.
7. **Only then** create/update the prefab and catalog entry and place it through
   the game's builder. Never hand-edit scene YAML. For interactive content,
   finish [prop checks](../yetikit-add-prop/SKILL.md), including both-hand grip
   and a real release-path throw replay.
