# Playtest code map

See the [playtest package guide](../../Packages/com.abominable.yetikit.playtest/README.md)
for opt-in capture, voice notes, and delivery. Playtest assemblies remain
behind the development define constraints.

| Area | Entry point | Responsibility |
| --- | --- | --- |
| Snap capture | [`SnitchCam`](../../Packages/com.abominable.yetikit.playtest/Runtime/SnitchCam.cs) | `TrySnap` collects a strip. `BeginSnap` stages the still locally for an optional note. Both can use the speech-onset frame and drain publication through `TryShutdown`. |
| Speech onset | [`SnapAnchor`](../../Packages/com.abominable.yetikit.playtest/Runtime/SnapAnchor.cs), [`FrameSelection`](../../Packages/com.abominable.yetikit.playtest/Runtime/FrameSelection.cs) | Convert an onset sample to frame-clock time, then select the nearest retained frame or fall back to a fresh still. |
| Deferred note | [`PendingSnap`](../../Packages/com.abominable.yetikit.playtest/Runtime/PendingSnap.cs) | Main-thread handle for attaching encoded WAV bytes, publishing, or cancelling. `SnitchCam.Tick` publishes an expired snap without a note. |
| Local handoff | [`DeferredSnapBatch`](../../Packages/com.abominable.yetikit.playtest/Runtime/DeferredSnapBatch.cs) and [`SnapDelivery`](../../Packages/com.abominable.yetikit.playtest/Runtime/SnapDelivery.cs) | Pending directories stay invisible to uploads until renamed. File-store startup recovery commits orphaned snaps without a WAV. Both flows use the same snap manifest. |
| Regression tests | [`DeferredSnapTests`](../../Packages/com.abominable.yetikit.playtest/Tests/EditMode/DeferredSnapTests.cs) | Anchored and fresh frame capture, note attachment, timeout, cancellation, restart, and deferred quit. |

For a voice command, compute `onset` with `SnapAnchor.FromSample(phrase.OnsetSample, sampleRate, micStartOnFrameClock)`,
then call `cam.BeginSnap(head, now, phrase.Text, anchor: onset)` on the main thread.
