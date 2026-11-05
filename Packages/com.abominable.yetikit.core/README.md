# YetiKit Core

Build identity, What's new notes, profiler-counter helpers and retry timing for
Unity 6000.6. No XR, UI or consumer-game dependencies.

## Assemblies and tests

All assemblies have `autoReferenced: false`. Add `YetiKit.Core` to the
consumer runtime asmdef's references and `YetiKit.Core.Editor` (plus
`YetiKit.Core`) to the consumer's Editor-only build assembly. No automatic
build callback is installed.

The EditMode assembly is `YetiKit.Core.Tests`. To discover its tests, install
Unity Test Framework in the host and add `com.abominable.yetikit.core` to the
host manifest's `testables`. Some counter tests yield frames; process tests
require `/bin/sh` and skip on platforms without it.

## Runtime API (`YetiKit.Core`)

- `BuildInfo`: immutable-property build record (`Number`, `Sha`, `Date`,
  `Notes`, `Known`, `Id`). Construct with number, SHA, UTC time and notes;
  `ToJson()` / `Parse(json)` round-trip it. `Unknown` represents a dev build;
  `Current` reads and caches `Resources/Generated/BuildInfo.json` on the main
  thread. `BuildId(info, version, guid)` falls back to a version/GUID identity.
- `info.Header(productName, zone = null)` formats a caller-named header.
  `info.Header(zone = null)` uses `Application.productName` on the main thread.
  Null time zones display UTC explicitly; use `Header(zone: null)` rather than
  the ambiguous `Header(null)` when selecting the default-product overload.
- `BuildTime.Stamp(utc)`, `Label(baked, zone)` and `ResolveZone(read)` handle UTC
  stamps, local display, legacy date-only records and unavailable device zones.
- `Backoff.Delay(failures)`: 0 for no failures, then 5 seconds doubling to a
  300-second cap.
- `IPerfCounter` / `ProfilerPerfCounter(category, name, capacity = 1)`: bind a
  Unity profiler recorder, expose sample count/latest/maximum, clear samples
  without unbinding, and dispose it. The interface permits synthetic counters.
- `PerfCounterSlot(name, start, retrySeconds)`: call `Tick(now)` each frame;
  invalid counters retry until first valid. `LastValue`, `PeakValue`, `Starts`
  and `Valid` expose state. `TakeIntervalMax()` consumes the interval and
  clears buffered samples. Call `Dispose()` when finished.
- `PerfCounterText.RenderCountersMeasured(valid, values)` and `Format(...)`
  distinguish unavailable render statistics (`n/a`) from measured zeroes.
  Pass slots' lifetime peaks to keep measurement state across quiet frames.
- `PerfWarmup(frames = 60)`: `Tick(sceneLoaded)` opens after consecutive ready
  frames and stays open. The caller determines readiness; no scene is named.
- `TextureMemoryDiagnostic.ShouldCapture(bytes, now, lastCapture)` gates high
  memory reports (over 256 MiB, at least 60 seconds apart). `Capture(bytes)`
  logs the largest texture objects under `[YetiKit]` in Editor/development
  builds only. The caller tracks capture time. Estimates are not exact GPU
  residency or process memory, and capture does not enable texture CPU reads.

## Editor API (`YetiKit.Core.Editor`)

- `BuildStamp.Collect(utc, notesEnv = BuildStamp.NotesEnv,
  prevShaEnv = BuildStamp.PrevShaEnv)` reads first-parent commit count and
  short SHA from git. Git runs in the Unity project's current directory
  (which must be inside the consumer checkout). Git failure or incomplete or
  unverified history warns and yields build zero rather than failing the build;
  `For` leaves version settings unchanged for build zero.
- `YETIKIT_WHATS_NEW` names a UTF-8 notes file. A readable empty file means no
  notes. If absent/unreadable, merge titles since `YETIKIT_PREV_SHA` (a hex
  SHA) are used; absent/invalid SHA or failed range query falls back to the
  last eight merges. Override the environment-variable names per `Collect`
  call if a consumer needs its own names. `Git` and `Env` delegates are
  injectable for tests; restore them after use.
- `ReleaseNotes.FromText(text)` and `FromMerges(log)` create up to 12 bullets,
  at most 120 characters each. `GitFormat` defines the merge-log separators.
- `BuildStamp.For(info, assetPath = BuildStamp.AssetPath)` returns an
  `IDisposable` scope that writes/imports the Assets-relative JSON path and, for positive build numbers, temporarily sets
  bundle version to `1.0.<number>` and Android version code to the number.
  Disposal restores both versions and removes the generated JSON and empty
  generated directories, including on build exceptions. `Remove()` performs
  explicit generated-asset cleanup; pass the same optional asset path to it.
  A custom Resources key can be read with `BuildInfo.Parse` on the loaded text;
  `BuildInfo.Current` always uses the default key.

### Consumer build wiring

**Full Git history is required before assigning version codes.** `Collect`
checks `git rev-parse --is-shallow-repository` and only accepts the count when
that query reports `false`; otherwise it warns and returns unknown build zero,
so `For` does not assign a truncated count to version settings. For GitHub Actions,
configure `actions/checkout@v4` with `fetch-depth: 0`. Other CI systems must also
fetch the complete history. Before invoking Unity or the build method below,
validate the checkout and fail the build if history is incomplete:

```sh
test "$(git rev-parse --is-shallow-repository)" = false || { echo "Build stamping requires full Git history" >&2; exit 1; }
```

Call the scope from an Editor build method only after that validation, around
the synchronous player build; no scene builder or specific build target is required:

```csharp
using System;
using UnityEditor;
using UnityEditor.Build.Reporting;
using YetiKit.Core.Editor;

public static class ConsumerBuild
{
    public static BuildReport Build(BuildPlayerOptions options)
    {
        var info = BuildStamp.Collect(DateTime.UtcNow);
        using (BuildStamp.For(info))
            return BuildPipeline.BuildPlayer(options);
    }
}
```

Reserve `Assets/Resources/Generated/BuildInfo.json` for generated data only:
its resource key is shared with `BuildInfo.Current`, and cleanup deletes it
rather than restoring an existing file. Ignore that file and its `.meta` in
the consumer's git configuration. Do not nest stamping scopes or leave one
open across asynchronous builds. The version policy is deliberately small;
consumers needing a different version scheme should own that build policy
rather than edit the installed package.
