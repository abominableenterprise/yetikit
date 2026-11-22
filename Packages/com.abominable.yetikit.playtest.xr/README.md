# YetiKit Playtest XR

Install `com.abominable.yetikit.playtest.xr` alongside the kit packages at the
same tag. The [base playtest package](../com.abominable.yetikit.playtest/README.md)
does not require XR. Reference `YetiKit.Playtest.XR` (and any kit assembly whose
types you use) from your development-only composition assembly. In the Editor
it is available in Play Mode; for players, build with **Development Build** and
`YETIKIT_DEV`. It does not compile into a non-development player.

From the starter's development bootstrap, call once on the main thread from
`Start` or a runtime initialization method:

```csharp
using YetiKit.Playtest.XR;

// With no identity or interaction sources:
PlaytestXR.Attach();

// Or, instead, with consumer-supplied identities and a prop to observe:
PlaytestXR.Attach(playerIdentity, buildIdentity, new FlightEvents(prop, "test-prop-1"));
```

Use nonpersonal player and prop IDs. The first successful attachment owns the
configuration for the lifetime of the app; repeated calls do not add producers.
No recording starts in batch mode. Recordings are local, under
`Application.persistentDataPath/playtest/outbox`. The host flushes and stops on
quit, or pauses while Unity suspends or the headset reports that it is not worn.
A brief pause resumes the same session; a pause over five minutes starts a new
session and rereads the supplied identities. If the headset does not expose
wear detection, Unity's application pause signal still applies.

The host samples the active kit `PlayerHand` on each side at up to 30 Hz into
`f` records. `L` and `R` contain a world-space pose for a tracked hand or active
controller, or `mode: none` if neither is available. `j`, when present, is a
flat sequence of world-space position/quaternion tuples in XR Hands joint
index order. `FlightEvents` emits `grab`, `release`, and (only for committed
launches) `throw`, keyed by the supplied prop `id`; `throw` also carries the
linear velocity `v` in world space. The optional sources are subscribed only
while recording. Supply sources for props that live as long as the recorder.
