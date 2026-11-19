# YetiKit Playtest

Local recording for the Editor, development builds, or builds defining
`YETIKIT_DEV`. Reference `YetiKit.Playtest` from an assembly with the same
constraint. The package doesn't start recording by itself.

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

Recordings stay under `<root>/outbox/<session>/`. They contain `meta.json`,
gzip JSON Lines chunks rotated every 60 seconds, and `session.done` after
finalization. The disk store flushes final metadata before publishing the
marker, including directory entries on Linux, macOS and Android filesystems
that support directory sync. Each in-flight chunk uses a temporary `.journal`: a four-byte
little-endian length followed by a UTF-8 record. Length prefixes keep recovery
independent of gzip member parsing. Startup recovery publishes the complete
records as one ordinary gzip chunk, counts any torn tail, and removes the
journal. It still handles old gzip temporaries and skips unknown formats.

Set `pendingDiskBudgetBytes` on the store to opt into pruning. The pump checks
at session start, rotation and completion; only completed sessions with no
pending files are eligible, oldest session ID first. Protected sessions still
count toward the budget, so it may be exceeded until they finish or are removed.
Run recovery and recording exclusively for a recording root. There is no
network transport or built-in event producer.
