---
name: yetikit-add-tunable
description: Expose a feel value on the in-headset tuning panel with persistence and capture context; use when a playtester needs to compare settings.
---
# Add a tunable

`Tuning.Float`, the panel, persistence, capture context and Bake are **(planned API,
see [docs/design.md](../../docs/design.md))**, not implemented in this skeleton.

1. Choose one question and the smallest useful knob set. Define a stable,
   namespaced key, safe min/max, units and the game-owned preset default.
2. In the experiment binding registered from the game's composition root,
   declare the explicit getter/setter; no attributes, reflection or boot scan:

   ```csharp
   Tuning.Float("throw/assist", 0, 1, () => cfg.assist, v => cfg.assist = v);
   ```

   `cfg` is the game's configuration object, not a new kit type. Keep this
   binding in the game's `Dev` asmdef constrained by `YETIKIT_DEV`.
3. Apply safe feel changes live. For a value that could invalidate a held grip
   or active charge, define and test a safe application boundary (next grab or
   charge), rather than changing the gesture halfway through it.
4. Persist overrides per experiment, visibly distinguish **preset / override**,
   and make Reset remove the override. Test change→restart→restore, Reset and
   a changed shipped default with a stale override. Do not duplicate defaults
   in a second persistence table.
5. Include build, kit tag, experiment ID, preset version and current overrides
   in each snap and session header. Verify capture-time values, not a later
   read from mutable configuration. Take a snap after changing the slider.
6. To bake preferred values, the playtester uses Bake: it tags the snap
   `bake: true` and exports overrides as JSON. Inspect that context, then copy
   agreed values into game-owned defaults in a normal reviewed PR; update the
   preset version and tests. Reset local overrides to verify the new preset.
   Do not build an automatic preset rewriter without a loading contract.
7. Test release stripping: no panel, bindings or dev-only references remain.
