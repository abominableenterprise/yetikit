# Playtest code map

See the [playtest package guide](../../Packages/com.abominable.yetikit.playtest/README.md)
for opt-in capture, voice notes, and delivery. Playtest assemblies remain
behind the development define constraints.

| Area | Entry point | Responsibility |
| --- | --- | --- |
| Snap capture | [`SnitchCam`](../../Packages/com.abominable.yetikit.playtest/Runtime/SnitchCam.cs) | `TrySnap` selects a history frame and collects a strip. `BeginSnap` renders a still immediately, shows the existing Polaroid, and stages it locally. Both drain publication through `TryShutdown`. |
| Deferred note | [`PendingSnap`](../../Packages/com.abominable.yetikit.playtest/Runtime/PendingSnap.cs) | Main-thread handle for attaching encoded WAV bytes, publishing, or cancelling. `SnitchCam.Tick` publishes an expired snap without a note. |
| Local handoff | [`DeferredSnapBatch`](../../Packages/com.abominable.yetikit.playtest/Runtime/DeferredSnapBatch.cs) and [`SnapDelivery`](../../Packages/com.abominable.yetikit.playtest/Runtime/SnapDelivery.cs) | Pending directories stay invisible to uploads until renamed. File-store startup recovery commits orphaned snaps without a WAV. Both flows use the same snap manifest. |
| Regression tests | [`DeferredSnapTests`](../../Packages/com.abominable.yetikit.playtest/Tests/EditMode/DeferredSnapTests.cs) | Fresh frame capture, note attachment, timeout, cancellation, restart, and deferred quit. |
