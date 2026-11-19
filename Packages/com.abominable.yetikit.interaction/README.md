# YetiKit Interaction

`YetiKit.Interaction` provides throw history and release math, rig carry, hand-off
rules, held-collision helpers, and hit and respawn decisions. It depends on
Unity physics, not the hands package or an XR interaction framework. Consumers
own motion sampling, object selection, and the application of rule results.

## Policies supplied by the consumer

- Seed respawn policy with `PropRespawnSettings.Default`, customize the area,
  floor and timings, then pass it to `PropRespawnRules`. The caller measures
  idle time and continuous time outside the area and decides when to move a prop.
- Pass a list of `ThrowTarget` values to `ThrowAssist.ApplyMoving`, or register an
  `IThrowTargetSource` with `ThrowTargetSource.Register` and call the overload
  without a list. Registration replaces the active provider. Dispose the returned
  handle when the provider is no longer needed; Unity also clears it on subsystem
  registration. The consumer selects aim points and marks reliable velocities.
  An explicit list bypasses the registered provider.
- Tag tracked palm samples with `ThrowSources.HandPalm`. Feed samples and tracking
  transitions to the release helpers; no kit component samples devices for you.

Run the pure EditMode fixtures through the [Unity test Host](../../Host/README.md)
with `-testFilter YetiKit.Interaction.Tests`.
