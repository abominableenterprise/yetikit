# YetiKit Playtest

Local recording for the Editor, development builds, or builds defining
`YETIKIT_DEV`. Reference `YetiKit.Playtest` from an assembly with the same
constraint. The package doesn't start recording by itself. For the optional
hand/controller recorder and interaction adapter, see
[Playtest XR](../com.abominable.yetikit.playtest.xr/README.md). See also the
[playtest code map](../../docs/codemap/playtest.md).

## Voice notes (opt-in)

- Provide `IPhraseGrammar` with stable lists of start and send phrases, or use
  `DefaultPhraseGrammar` (`start`, `send it`). Commands are whole phrases,
  compared without case or extra whitespace. Use one `PhraseRules` per stream
  and pass monotonic seconds; a partial and its final can only trigger once.
- Implement `IMicrophonePermission` and `IMicrophoneCapture` in the host. Call
  `MicrophoneArming.Arm` after explicit opt-in, `Poll` on the main thread, and
  `Stop` on teardown. The host owns the captured samples and file lifecycle.
- Feed consecutive 16 kHz mono signed PCM16 blocks to `RecognitionWorker`.
  `TryEnqueue` copies each accepted block. If its two-second queue is full,
  retry the same block before later samples or restart the recognition stream.
  `Phrase` runs on the worker: hand off results to the main thread before
  driving rules, notes or Unity objects. Check `Failure` if recognition stops.
  For Editor input, bind a key to `KeyboardPhraseSpotter.TryFire` and enqueue a
  nonempty synthetic PCM block; no permission or native plugin is needed.
- `VoiceNote` tracks time by samples (not by frames or wall clock): it ends on
  send, three seconds of quiet after a known phrase, eight seconds of quiet
  otherwise, or 90 seconds total. Pass each block to `Process`; the increase in
  `SamplesConsumed` tells you how much of that block to retain. Use `WaveEncoder`
  on the retained PCM. `AudioFeedback` generates start and confirmation clips;
  create, play and destroy them on the main thread.

### Optional Android recognizer

For an Android development build, supply a [Vosk Android AAR](https://alphacephei.com/vosk/install)
under the host's `Assets/Plugins/Android` (or via its Gradle dependencies).
Include its native `libvosk.so` and dependencies for the player ABI (e.g.
`arm64-v8a`); the adapter calls the C API directly. Use a small
[grammar-capable model](https://alphacephei.com/vosk/models) for the language of
the command phrases. Extract it into an ordinary readable directory (for
example, under `Application.persistentDataPath`); an APK or StreamingAssets
URI is not a model directory. Pass that absolute directory and the same
`IPhraseGrammar` used by `PhraseRules` to `VoskPhraseSpotter`, then transfer
ownership to `RecognitionWorker`.

Set `YETIKIT_VOSK` alongside `YETIKIT_DEV` for the Android dev build. The
adapter isn't compiled without the Android and Vosk defines. Guard host code
that constructs it with `YETIKIT_VOSK && UNITY_ANDROID && !UNITY_EDITOR`.
The host must keep the AAR, model and any microphone permission out of
non-dev builds; scripting defines alone do not exclude Android assets.

## Local recording

Create a `FileChunkStore` for your recording root and share it between a
`ChunkPump` and a `RecordingSession`. Call `RecoverChunks` at startup before
recording. Use `SessionRules.NewId` for each new session and supply optional
build, player, and device metadata through `SessionMeta`. Drive the session's
`Begin`, `Tick`, `Pause`, `Resume`, and `End` from the main thread and dispose
of the pump after the last session. Use one active session per log and pump.

Producers call `FlightLog.AppendEvent(kind, payload)` or register an
`IFlightEventSource` and dispose its registration when finished. Payloads are
JSON values; object fields are merged into the record unless the object uses
recorder-owned `t` or `k` keys at the top level, in which case it stays under
`d`. An optional
`IEventClassification` controls counts and whether events keep short sessions.
`AppendEvent` returns `Appended` when a record enters memory, `BufferFull`
when backpressure rejects it, or `Sealed` after the session ends. Acceptance
is not a disk acknowledgment. `FlightLog` takes an optional
`maxBufferedChars` limit; the worker accepts up to three queued/in-flight
buffers plus a reserved pause/end slot. `BackpressureDrops` counts the
producer-side losses. `meta.json` checkpoints `lost.count` and the earliest
and latest lost record times (`lost.first` / `lost.last`, null if unavailable).
`lost.torn` counts interrupted journal tails whose records cannot be read.
In `session.done`, `context.lostRecords` counts worker and producer losses;
`context.lost` remains the legacy worker-only count of uncompressed characters.

Recordings stay under `<root>/outbox/<session>/`. They contain `meta.json`,
gzip JSON Lines chunks rotated every 60 seconds, and `session.done` after
finalization. The disk store flushes final metadata before publishing the
marker, including directory entries on Linux, macOS and Android filesystems
that support directory sync. Each in-flight chunk uses a temporary `.journal`: a four-byte
little-endian length followed by a UTF-8 record. Length prefixes keep recovery
independent of gzip member parsing. Startup recovery publishes the complete
records as one ordinary gzip chunk, counts any torn tail, and removes the
journal. It still handles old gzip temporaries and skips unknown formats. A
malformed metadata temp is discarded only when supported committed metadata
is available; explicitly unsupported formats are left untouched. If rollback
of a failed journal write is blocked, the recorder tries to save the last
committed byte offset for startup recovery. If storage rejects that checkpoint
too, recovery can only infer completeness from the frames on disk.

Set `pendingDiskBudgetBytes` on the store to opt into pruning. The pump checks
at session start, rotation and completion; only completed sessions with no
pending files are eligible, oldest session ID first. Protected sessions still
count toward the budget, so it may be exceeded until they finish or are removed.
Run recovery and recording exclusively for a recording root.

## Snap capture (`YETIKIT_DEV`)

Drive `SnitchCam` on the main thread with a camera, a monotonic clock, and
host-owned input and consent. Pass `SnapDelivery` as the publication store
for local capture or to queue a separate snap batch in the outbox. Acceptance
by `TrySnap` is not a disk acknowledgment. Keep using it for a history-based
snap with a frame strip and, optionally, a WAV already encoded by the host.

For hold-to-talk, `BeginSnap` renders a fresh still and stages its JPEG and
context on disk before returning. It shows the same Polaroid at capture time
and does not collect a strip. Call it with a `SnapDelivery` store. A null handle
means the snap wasn't accepted (for example, the camera is busy or staging
failed). Only one snap per `SnitchCam` can wait for a note, encode a strip, or
publish at a time. Continue calling `Tick` with the same monotonic clock.

```csharp
// At press; only start recording on hold, after microphone opt-in.
var pending = cam.BeginSnap(head, now);
// At release; wave is an encoded WAV, or null for a tap.
if (pending != null)
{
    if (wave != null) pending.AttachNote(wave);
    pending.Publish();
}
```

`AttachNote` copies the WAV into memory. `Publish` submits it and starts local
publication; observe `SnapOutcome` for the result. A successful `Cancel`
discards the snap. Unsubmitted notes are dropped on timeout (30 seconds by
default, configurable via `noteTimeoutSeconds`), shutdown, or restart. Those
paths publish the JPEG and JSON without a WAV. On startup, call `RecoverChunks`
(or use `PlaytestUpload.Attach` with uploads enabled), before starting capture
on that root, to finish orphaned snaps. Recovery keeps the local/queued routing
chosen at capture time.

Before allowing a controlled quit, call `TryShutdown(timeoutMs)` on the main
thread **before** disposing the frame history. It stops new captures, finishes
encoding the available strip frames, then waits up to the specified time for
local publication, not network upload. If it returns `false`, keep the app
alive and retry (for example, defer quit via `Application.wantsToQuit` and use
`TryShutdown(0)` on subsequent updates). When it returns `true`, check
`SnapOutcome` for the result: `Local` or `Queued` means stored; `Failed` means
publication failed. `Dispose` alone starts publication but does not wait for
it, and abrupt process termination can still interrupt an unfinished write.

## Optional delivery (`YETIKIT_DEV`)

`PlaytestJsonSettings.LoadDefault()` reads the first readable `playtest.json`:
`Application.persistentDataPath/playtest/playtest.json`, then `files/playtest.json`
in the Android app-private directory. Supply `endpoint`, `uploadKey`, and `player`
(an ASCII path segment). In the Editor, `YETIKIT_PLAYTEST_ENDPOINT` and
`YETIKIT_PLAYTEST_KEY` override credentials as a pair; `YETIKIT_PLAYTEST_PLAYER`
overrides the player separately. Keep these credentials out of version control.
No config means no network. Use HTTPS except for local loopback testing.

Call `PlaytestUpload.Attach(session, settings)` on the main thread **before**
`Begin`, once per `FileChunkStore`. It does startup recovery without network
access, including publishing recoverable abandoned sessions. Reuse the returned
`Uploader` for subsequent sessions on that store and call `TickAsync` from the
main-thread update; pass a lifetime cancellation token. Only completed batches
are sent: the uploader PUTs metadata and chunks serially, then posts the
manifest with a stable idempotency key. Unacknowledged batches persist and are
replayed after restart. A batch rejected with HTTP 400, 413, 415, or 422 is
skipped across restarts while later batches continue. Its files stay on disk
subject to the outbox budget; remove its `.rejected` marker to retry after
correcting the cause. Successful batches are removed locally. With
`SnapDelivery`, the uploader sends each snap as its own batch and posts
`kind: snap` to `/done`.
`NetWarmup.PingAsync` optionally checks the endpoint without the upload key.

A consumer can pass `ILiveTuningSource` to its lab integration without linking
this package to lab. Read `CurrentJson` for the initial override, subscribe to
`Changed` to parse and apply validated overrides, and treat `null` as clearing
remote overrides. Start `LiveTuningClient.PollAsync` on the main thread with a
lifetime token, or call `RefreshAsync` from your own scheduler; unsubscribe and
cancel when the consumer stops.
