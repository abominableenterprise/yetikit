# Lab

Reference `YetiKit.Lab` from a consumer assembly gated the same way: available
in the Unity Editor, or in a development player built with `YETIKIT_DEV`.
A release player cannot include the assembly just by defining `YETIKIT_DEV`.

- Register fresh per-hand factories with `Experiments.Add` after subsystem
  registration. Dispose the returned token to remove a factory. An
  `ExperimentSwitcher` owns both instances of the current experiment. Call
  `Tick` after reading input and dispose the switcher on teardown. Its optional
  input lease should capture previous input state and restore it on disposal.
  Only explicit selections write to the per-lab store.
- Call `DevBoot.Launch` at startup with a policy that returns a scene and
  optional experiment ID (an empty scene leaves startup unchanged). The target
  scene can pass `DevBoot.Consume` to the switcher as its initial ID. Consumers
  supply scenes, rigs and selection views.
- Create one `Tuning` model per experiment ID to bind live values. Call `Tick`
  with unscaled seconds for debounced persistence and `Flush` on teardown or
  pause. Reset by ID, group or all registered bindings; values for IDs not
  currently registered survive. The default PlayerPrefs store saves a versioned
  JSON document with a `values` array of ID/value pairs.
- Place `TuningPanel` on a world-space canvas, wire its label, navigation and
  reset buttons, and put a `TuningHoldButton` on each adjustment target. Use the
  rig's UI pointer and raycaster. Call `Bind` when the active tuning model changes.
