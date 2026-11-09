# Changelog

All notable changes are documented here in Keep-a-Changelog style.
Every release must include **Added / Fixed / Behaviour changes / Adapter changes**
(what a consumer game must edit), even if a section says "None".
Before 1.0, minor releases may break compatibility only with explicit adapter
notes. Chunk and tuning schema changes count as breaking changes too.

## [Unreleased]

### Added
- None.

### Fixed
- Quest performance capture waits for a cold-started app's unique PID before
  warm-up, while retaining identity and foreground checks.
- Proximity restoration is timeboxed during capture cleanup and cancellation;
  failed restoration records a manual recovery warning without blocking final
  results or lock release. Successful retries clear their matching marker.

### Behaviour changes
- Optional `QR_PERF_PID_WAIT` (20 seconds) bounds initial PID discovery;
  optional `QR_PERF_RESTORE_WAIT` (10 seconds) bounds each restoration attempt.

### Adapter changes
- None.

## [0.1.7] - 2026-11-09

### Added
- Repeatable Quest performance windows with warm-up exclusion, per-model
  frame-time/stale-frame gates, text/JSON reports and proximity restoration.

### Fixed
- Ship's Quest release tests no longer depend on VM speed.
- Filtered EditMode runs no longer fail solely because one pass selects no tests.

### Behaviour changes
- None.

### Adapter changes
- None; optional `quest.perf`.

## [0.1.6] - 2026-11-09

### Added
- None.

### Fixed
- Filtered EditMode runs no longer fail solely because the pure or Gfx pass
  selects no tests when the other pass executes the matching tests.

### Behaviour changes
- Filtered two-pass EditMode runs allow per-pass empty selections with valid
  result XML, but the combined executed count must be greater than zero.
  Filters matching neither pass fail with a diagnostic naming the filter.

### Adapter changes
- None (the EDITMODE_GFX=0 workaround is no longer needed).

## [0.1.5] - 2026-11-09

### Added
- Quest release runs can install and launch the same build on several headsets,
  with ordered device steps, isolated diagnostics and crash-only rollback.
- Optional `quest.signing` maps environment-variable names for release-keystore
  certificate lookup, with PKCS12/JKS autodetection. The consumer build retains
  responsibility for signing using its inherited environment.

### Fixed
- None.

### Behaviour changes
- Multi-headset runs store device artifacts in separate encoded-serial folders
  and report each device's outcome. Single-headset paths and behavior are unchanged.
- None for projects without signing config; existing debug-keystore behavior
  is unchanged.

### Adapter changes
- Optional adoption: configure `quest.signing.keystorePathEnv`, `storePassEnv`
  and `keyAliasEnv`, plus `keyPassEnv` if needed by the consumer build. Supply
  the mapped environment variables, set `QUEST_CERT_SHA256` to the release
  certificate fingerprint and run `quest-release.sh doctor` before building.

## [0.1.4] - 2026-11-09

### Added
- None.

### Fixed
- Android setup re-checks for running editors after cleanup and refuses replacement if an editor started during the cleanup delay or process inspection is incomplete.

### Behaviour changes
- None.

### Adapter changes
- None.

## [0.1.3] - 2026-11-08

### Added
- None.

### Fixed
- Cleanup and `stop` keep shared Unity memory while an editor from another Unity installation is running.
- `test-all.sh --changed` now selects tests when Ship is vendored under another directory, instead of passing with no tests.
- The Quest release gate reads the known-flakes list from the commit under test, falling back to the main checkout.
- Test passes and known-flake retries now require result evidence instead of
  trusting a successful editor exit alone
  ([#34](https://github.com/abominableenterprise/yetikit/issues/34), Part 1).
- Shared Unity memory and the project lockfile are kept when a running process can't be inspected (for example another user's editor), instead of being treated as absent.
- Distinguish launch infrastructure failures from confirmed package crashes so
  failed device, adb, activity-start or logcat checks cannot downgrade a healthy
  installed build. Process probes preserve transport and remote exit status.

### Behaviour changes
- A pass with no executed tests or no result XML now fails; `-quit`,
  `-testResults` and `-logFile` are rejected as forwarded test arguments.
  Only the implicit, unfiltered EditMode Gfx pass and PR Gfx pass may select
  zero tests with valid XML; retries must always execute tests.
- Launch infra errors are reported as `INFRA` and never trigger rollback;
  rollback in `all` no longer implies `--force`. Standalone `launch` returns
  0 for success, 1 for a confirmed crash, and 3 for infrastructure errors.

### Adapter changes
- Remove any forwarded `-quit`/`-testResults`/`-logFile` from test invocations.

## [0.1.2] - 2026-11-08

### Added
- None.

### Fixed
- `linux-unity.sh stop` no longer deletes shared Unity memory or the project lockfile while another editor is running.

### Behaviour changes
- None.

### Adapter changes
- None.

## [0.1.1] - 2026-11-08

### Added
- Optional test and code roots for Ship's PR Gfx selection, area tests and
  RenderTool discovery
  ([#27](https://github.com/abominableenterprise/yetikit/issues/27)).

### Fixed
- Editor cleanup only signals editors and helpers carrying the current runner's
  ownership marker, protecting editors started outside that run
  ([#28](https://github.com/abominableenterprise/yetikit/issues/28)).

### Behaviour changes
- Foreign editors are no longer killed by runner cleanup. Shared-memory and
  project lockfile removal is skipped with a warning while an editor under the
  configured installation remains. Android setup refuses to replace that
  installation until its remaining editors and helpers exit. Installation paths
  are canonicalized, and replacement uses a privileged read-only process scan;
  failed inspection refuses replacement without removing shared resources.

### Adapter changes
- None for cleanup ownership changes.
- Optional; set `tests.root`, `tests.editModeRoot`, `tests.scriptsRoot` and
  `tests.editorRoot` if your tests aren't under `Assets/Tests` or code uses a
  nonstandard layout. Defaults preserve existing selection; `editModeRoot`
  defaults to `<tests.root>/EditMode`.

## [0.1.0] - 2026-11-05

### Added
- Public MIT kit skeleton, adoption/design documentation and seat-free CI
  ([#1](https://github.com/abominableenterprise/yetikit/pull/1)).
- Shared agent skills and consumer starter templates
  ([#2](https://github.com/abominableenterprise/yetikit/pull/2)).
- Configurable Linux Unity runner with licensing, test passes, build helpers and
  offline synthetic regressions
  ([#3](https://github.com/abominableenterprise/yetikit/pull/3),
  [#4](https://github.com/abominableenterprise/yetikit/pull/4)).
- Quest release pipeline, device safety gates, backup verification and offline CI
  ([#7](https://github.com/abominableenterprise/yetikit/pull/7),
  [#9](https://github.com/abominableenterprise/yetikit/pull/9)).
- Coordinated package pins and byte-for-byte Ship vendoring with digest and
  dependency-closure checks
  ([#10](https://github.com/abominableenterprise/yetikit/pull/10)).
- Minimal Unity test Host and licence-free script metadata/assembly checks
  ([#12](https://github.com/abominableenterprise/yetikit/pull/12)).
- Opt-in core build identity, release notes, performance counters and utilities
  without XR dependencies
  ([#13](https://github.com/abominableenterprise/yetikit/pull/13)).
- Static mesh checks for holes, inverted surfaces and topology defects
  ([#17](https://github.com/abominableenterprise/yetikit/pull/17)).
- Editor-only quality validators for missing scripts, GUID collisions, placement
  contracts and release assembly/permission audits
  ([#18](https://github.com/abominableenterprise/yetikit/pull/18)).

### Fixed
- Unity credentials remain available to leased follow-up tasks
  ([#16](https://github.com/abominableenterprise/yetikit/pull/16)).
- Watcher regressions synchronize on observed readiness and remain deterministic
  under CPU load
  ([#21](https://github.com/abominableenterprise/yetikit/pull/21)).
- Every editor command cleans configured generated noise, including failed runs,
  while preserving authored changes
  ([#23](https://github.com/abominableenterprise/yetikit/pull/23)).

### Behaviour changes
- Build headers use the consumer's product name; build notes use kit-neutral
  environment variables.
- Core and quality assemblies require explicit opt-in; quality has no runtime or
  core dependency. Other package skeletons remain planned, not part of 0.1.0.
- Consumer package closures and vendored Ship tooling are pinned together at one
  tag; local vendored patches are rejected by the integrity check.

### Adapter changes
- first release: adopt per [ADOPTION.md](ADOPTION.md).
