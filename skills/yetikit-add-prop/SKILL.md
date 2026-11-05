---
name: yetikit-add-prop
description: Add a grabbable and throwable prop with declared placement and grip; use when introducing or changing interactive prop content.
---
# Add a prop

Kit interaction and quality contracts below are **(planned API, see
[docs/design.md](../../docs/design.md))**; use only the installed version's
actual validators and entry points. Do not invent commands to fill gaps.

1. Read the game's props area guide. Define real-world scale, local forward,
   ground/support point and grip pose(s), including left/right hand offsets.
   Keep the visual mesh's import correction separate from gameplay forward.
2. Complete [asset intake](../yetikit-asset-intake/SKILL.md). Run mesh checks
   for winding, holes, outside rays, non-finite/degenerate geometry and negative
   scale; intentional openings must be declared, not globally ignored.
3. Build the game-owned prefab and register it in the prop/catalog builder.
   Configure collider, rigidbody mass and grab/release behavior through the
   game's existing composition hooks. Never hand-edit scene YAML.
4. Add placement coverage: support gap ≤2 cm, facing error ≤2° (planned quality
   contract). A raised anchor and reversed forward fixture must fail.
5. Check grip alignment **with both hands**, separately and during hand-off:
   wrist orientation, reach, collision clearance and release. Exercise hand
   tracking and controllers in a small per-area test scene.
6. Add a throw replay through real history→release→throw, asserting velocity
   on the first physics step, not just estimator math. Cover early grip open
   25–70 ms before peak, set-down, tracking loss, hand-off and teleport carry;
   use synthetic fixtures with prop-specific expected bands. Never quarantine
   throw replay failures.
7. Regenerate only the affected prefab/area with the game's supported builder,
   run focused tests, then show placement and both-hand grip evidence in review.
