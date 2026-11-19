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

## Grip lab station

A consumer supplies an `IInteractableCatalog` with unique stable IDs and one
prefab or factory per entry. Each must produce a fresh active `GrabbableProp`
with solid colliders on its rigidbody. Put `GripLabStation` at the midpoint of
an axis-aligned table's near edge at surface height, and call `Populate` once
at runtime. The station keeps authored rotations, wraps rows along world +Z,
and uses the combined solid collider bounds for spacing. Size the table depth
for the catalog and allow room for entries wider than the row width.

Props start fixed at their slots. Physical hand contact or XR selection makes
them dynamic. Unheld props return after three gameplay seconds, starting after
any late release has settled; props that fall out of the world recover directly.
Assign the optional Reset and Back buttons in the Inspector. Both return props
and cancel active grabs without throwing. Back then raises `BackRequested` for
the consumer's navigation. Props remain children of the station while held.

Set `Head` to the rig's head transform and register `FlightEvents` with the
session flight recorder (dispose the registration when leaving the lab). On
selection with available hand input, `griplab` v1 records `prop` (catalog ID),
`side` (`L` or `R`), `mode` (`controller` or `tracked_hand`), and `grip` (mode
profile ID, empty for an unnamed grip), plus two poses:

- `attach`: interactor attach pose in wrist space.
- `wrist`: wrist pose in head space. For controller input, the controller pose
  is the wrist reference.

Poses use Unity's left-handed axes (+X right, +Y up, +Z forward) for either hand,
with no mirroring. Each is `[px,py,pz,qx,qy,qz,qw]` in meters and quaternion
components; rotations map child axes into the parent frame.

### Grip overrides

Pass an `IGripOverrideStore` to `Populate` to load and save overrides by catalog
ID and `HandMode`. Use `PlayerPrefsGripOverrideStore` with a stable catalog scope
for local persistence; omitting the store keeps commits in memory. Per mode,
the lab preview or committed override wins over `gripProfiles`, which wins over
`grip`. The authored and baked data are never edited.

Use `station.Adjuster.Begin(slot, mode, competingInputs)` to select an edit target.
Supply only behaviours competing for adjustment input. The guard disables them,
except for tracked-hand interactors, where it blocks selection without stopping
tracking. Do not include the active holding interactor. `Stage(profile)`
previews a grip and refits any matching hold in place. `Commit()` saves the
preview. `Undo()` discards an active preview, or restores the last committed
state for that slot and mode. `Reset()` removes the override for that key and
can itself be undone. `End()` discards uncommitted changes. Borrowed input states
are restored on end, on Back, on station or slot disable, and on an adjuster
exception. The station's Reset button still returns props to their slots; it
does not delete saved grips.

The store handles a JSON body per key: `v` is `1`, and `profile` contains the
`id` and `spec` fields of `GripProfile`. Unknown fields in a valid v1 body are
ignored on read; an explicit edit replaces that key's body. Malformed or
unsupported bodies fall back to the baked or authored grip and cannot be
committed over or reset by the adjuster. Other keys are never rewritten.
