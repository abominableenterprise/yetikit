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
JSON values; object fields are merged into the record. An optional
`IEventClassification` controls counts and whether events keep short sessions.

Recordings stay under `<root>/outbox/<session>/`. They contain `meta.json`,
gzip JSON Lines chunks rotated every 60 seconds, and `session.done` after
finalization. Recovery handles chunk temporaries and leaves unknown metadata
formats untouched. There is no network transport or built-in event producer.
