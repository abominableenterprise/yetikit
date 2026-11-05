---
name: yetikit-add-experiment
description: Register a focused development experiment and direct boot route; use to test one gameplay or feel question without navigating the full game.
---
# Add an experiment

`Experiments.Add`, tuning and direct boot selection are **(planned API, see
[docs/design.md](../../docs/design.md))**; confirm support in the pinned kit.

1. Write **one experiment = one question**, its success criterion and what
   evidence a snap/session must contain. Give it a stable neutral ID.
2. Create a game-owned prefab with only the objects needed to answer that
   question. Reuse the sandbox rig; do not fork hands or interaction code.
3. Register from the game's composition root in its dev-only assembly:

   ```csharp
   Experiments.Add("throw-range", Open, Bind);
   ```

   `Open` is the game's `Func<GameObject>` prefab opener; `Bind` is its
   `Action<TuningScope>` explicit binding callback. These are proposed design
   signatures, not a requirement to implement a registry in the game.
4. Bind only relevant knobs with explicit `Tuning.Float` / `Tuning.Bool`
   (planned API); follow [tunable setup](../yetikit-add-tunable/SKILL.md).
5. When direct boot is available, use the pinned release tool's documented
   experiment selector. Boot into the experiment before the first rendered
   frame; an unknown ID must show the chooser with an error. Release builds
   ignore the selection. Do not guess launcher flags from another project.
6. Test fresh boot, unknown ID, normal scene re-entry and reload with domain
   reload disabled: no duplicate listeners or stale static selection. Keep
   dev code behind `YETIKIT_DEV`; verify it is absent from a release build.
7. Capture build/kit/experiment/preset/overrides with the result. Record what
   the experiment answered, not just that a prefab loaded.
