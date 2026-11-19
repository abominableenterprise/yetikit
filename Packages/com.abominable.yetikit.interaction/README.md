# YetiKit Interaction

`YetiKit.Interaction` provides throw history and release math, rig carry, hand-off
rules, held-collision helpers, and hit and respawn decisions. Its Unity adapters
use the Input System, XR Interaction Toolkit and YetiKit Hands.

## Policies supplied by the consumer

- Attach `PropGrabInteractable` and `GrabbableProp` to a rigidbody with colliders.
  Customize `GrabbableProp.RespawnSettings` for the scene's bounds, floor and
  timings. Configure the optional `HeldProp` layer and collision matrix in the host.
- A prop can register an `IThrownHitSink` through `GrabbableProp.HitSink`.
  Resolve eligible targets in the sink; `LaunchedPropContacted` also observes
  contacts that do not qualify as hits.
- A hand can supply `IHeldVisual` to fit an authored grip and wrap its fingers.
  Optional `IDistanceGrab` supplies reach and attachment timing for an external
  distance-selection or summon implementation.
- Pass a list of `ThrowTarget` values to `ThrowAssist.ApplyMoving`, or register an
  `IThrowTargetSource` with `ThrowTargetSource.Register` and call the overload
  without a list. Registration replaces the active provider. Dispose the returned
  handle when the provider is no longer needed; Unity also clears it on subsystem
  registration. The consumer selects aim points and marks reliable velocities.
  An explicit list bypasses the registered provider.
- Place `ControllerMotion` with the controller or hand root; assign its
  `PlayerHand` to opt into tracked-palm release sampling. Consumers feeding the
  pure release helpers directly can tag palm samples with `ThrowSources.HandPalm`.

Grip profiles remain nullable managed references. When migrating consumer assets
from another assembly, remap existing non-null `GripProfile` managed-reference
records to `YetiKit.Interaction.GripProfile` in assembly `YetiKit.Interaction`
before reserializing those assets; component GUIDs do not resolve managed types.

Run the EditMode fixtures through the [Unity test Host](../../Host/README.md)
with `-testFilter YetiKit.Interaction.Tests`.
