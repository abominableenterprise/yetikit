# Changelog

All notable changes are documented here in Keep-a-Changelog style.
Every release must include **Added / Fixed / Behaviour changes / Adapter changes**
(what a consumer game must edit), even if a section says "None".
Before 1.0, minor releases may break compatibility only with explicit adapter
notes. Chunk and tuning schema changes count as breaking changes too.

## [Unreleased]

### Added
- Set up a private playtest inbox for session uploads, webhook notifications, and live tuning.

### Fixed
- None.

### Behaviour changes
- None.

### Adapter changes
- None.

## [0.2.0] - 2026-11-22

Hands and interaction are now released alongside the development-only playtest
and lab modules. The new-game starter template generates a game-owned XR sandbox
with locomotion, local playtest tools and a release build audit.

### Added
- Release hands, interaction, playtest and lab at the same version as core and
  quality. Ship the starter with tracked hand and animated controller visuals,
  Point & Pinch hand teleport, and development-only aim diagnostics.
- Verify starter package sources before and after import. Document optional
  headset setup and permission review, and audit generated release players.
- Ship setup can install a pinned, verified crane binary on Linux x86-64
  without Go.

### Fixed
- Restore hand teleport independently of editor-generated layer settings,
  align controller visuals with the stock rig, and aim controller teleport from
  the pointer pose. Make the starter's target-hit cue easier to hear, recover
  interrupted photo pairs, and prevent a deep wrist poke from making two edits.
- Accept SCP-style SSH package URLs and host-only registry URLs in the starter
  verifier. Retain nested namespace fixtures in Ship PR test selection, and
  distinguish changed-test basename filters from Git refs.
- Preserve release worktrees with symlinked indexes or concurrent index edits,
  distinguish equal-time release results, and keep headset locks until isolated
  ADB workers exit.
- Keep retried performance stops from extending capture windows, and require a
  fresh capture if the stop guard is inaccessible or the stop reservation cannot
  be saved.

### Behaviour changes
- The generated starter uses a separate hand arc trajectory while retaining the
  controller ray's physics filters. Lab controls stay out of release players.

### Adapter changes
- Pin each selected kit package and its kit dependency closure to `v0.2.0`.
  Enable `YETIKIT_DEV` only for development use of playtest and lab. Existing
  baked starter scenes are not upgraded in place; generate a fresh sandbox to
  inspect or adopt the updated rig.

## [0.1.13] - 2026-11-19

Only core and quality are released consumer packages. Hands, interaction,
playtest and lab are included as previews and remain at `0.0.1`.

### Added
- Add tracked-hand curl and shape measurements, grab, poke, turn and teleport
  gesture detectors, and XR input adapters in the hands package.
- Add an art-free `PlayerHand`, optional `IHandVisual`, and palm-following
  `HandGrabInteractor`.
- Add hand teleport with an XRI arc and landing preview, rig-scoped aim
  ownership, hand snap turn, and an event-driven wrist button.
- Add the interaction package with throw and release math, configurable aim and
  respawn rules, and grip hand-off and carry helpers.
- Add reusable XRI props with per-mode grips and a catalog-driven Grip Lab
  with grip previews, saved adjustments and optional ghost hands.
- Add development-only local playtest recording with a durable outbox and
  recovery and retry for interrupted sessions.
- Add the development-only lab package for experiment switching and live tuning.
- Generate a game-owned starter sandbox with an XR rig and locomotion, desktop
  experiment boot, persistent tuning, XR wrist controls and local photo snaps.

### Fixed
- Release cleanup preserves worktrees with `assume-unchanged` or `skip-worktree`
  entries instead of removing them and losing hidden edits
  ([#282](https://github.com/abominableenterprise/yetikit/pull/282)).
- Quest release `wait` reports the right invocation and saved result through
  cancellation, lock handoffs and teardown, including legacy runs and removed directories.
- Quest cancellation keeps cleanup and reporting going when worker exit is
  uncertain. Ambiguous installs invalidate stale baselines, and a performance
  report failure no longer prevents restoring device proximity settings.
- Quest APK checks resolve launcher booleans in the active configuration and
  recognize annotated permission requests. Signing passwords stay out of tool overrides.
- Linux Unity keeps setup writes and worker cleanup ordered, rejects mismatched
  Android images without replacing the base editor, and avoids reusing licences
  pending return or seats that were released.
- Linux Unity preserves regenerated assets and abnormal test results during
  recovery. APK swaps and Bee cache recovery preserve symlinks and report
  restoration errors even if saving the APK cache also fails.
- Targeted PR tests combine equivalent builder paths, retain sibling fixtures
  after nested or verbatim C# strings, recognize multiline Gfx tests, and keep
  explicit render fixtures out of headless runs.
- Core builds independently and build stamping preserves existing folders.
- Mesh audits reject malformed inputs without overwriting source assets or
  external buffers; audit and repair preserve the winding of hollow solids.
- Tracked-hand input, gestures and locomotion recover from failed reads and
  callbacks without acting on stale input or leaving previews out of sync.
- Throw estimation uses valid motion history, prop grips and releases survive
  state changes, and Grip Lab rejects unusable colliders and restores input safely.
- Local playtest finalization reports storage failures accurately and preserves
  data for retry. Lab experiment and tuning lifecycles are safer; starter tuning
  becomes read-only when its saved data cannot be read.

### Behaviour changes
- Changed-mesh selection includes unchanged glTF and GLB files when a `.bin`
  buffer changes. See the [mesh checks guide](Tools/quality/README.md).
- Interactive Linux setup waits for privileged package writes to finish before
  honoring cancellation.

### Adapter changes
- Linux Unity setup uses `/usr/bin/python3` to supervise privileged writes.
- If Quest signing maps a password to a Git, SSH or Android tool override,
  move it to a dedicated uppercase environment variable.

The following adapter notes apply to the preview hands package only:

- `PlayerHand.glove` (serialized) is removed. Assign an optional `IHandVisual`
  through the inspector's `visual` field or `PlayerHand.Visual`. The gameplay
  root now follows the tracked wrist directly; implement any model offsets in
  the visual. `WristAlignment` remains consumer-side and was not ported.
- `IHandInput.Bird` and `PlayerHand.Bird` are removed; interpret `Shape` in the
  consumer. `PlayerHand.Report` now takes only grip and trigger (no `birdShown`).
  `PlayerHand.PoseEpoch` is removed; use `PresenceChanged` to detect mode changes
  when reseeding motion. `PlayerHand.FingerCurls` uses the kit's `FingerCurls` type.
- `HandGrabInteractor.Palm(GloveRig)` is replaced by `PlayerHand.PalmPose`.
  `HandGrabInteractor.PreservePausedSelection` is not ported; pausing is a
  consumer policy. The near grab only uses `HandFarInteraction.UiHover` and
  `Hover`. `HandFarInteraction.AllowsTeleport(held)` now checks only UI hover
  and held selection; other far-interaction priorities stay in the consumer.
- Set `HandTeleport.teleportLayerName` in the inspector (default `Teleport`),
  or set `TeleportLayerName` in code. `TeleportAim.Cast` takes the layer name;
  `Revalidate()` replaces `RevalidateUi()` and checks current UI and optional
  `Blocker` / `LandingAllowed` policies before confirming a frozen aim.
- `HandAimOwnership.For` takes a rig `Transform`, not a `PlayerHand`. `Claim`
  replaces its lock flag with an optional preemption callback. By default
  sibling hand roots share their parent's lease; assign `HandTeleport.rig`
  explicitly for hands under different parents.
- `HandUiGuard.Near(PlayerHand)` is not ported. Pass a point and a radius to
  the geometry query instead; the old `Reach` constant is `TeleportAim.UiReach`.
- `WristButton.toggle` (serialized) and the legacy style behavior are removed.
  Wire `Pressed` or `onPressed` for actions; record counts in a listener instead
  of using the removed `Presses` property. Author the wrist position on the
  transform instead of relying on the removed `BackOffset` / `CuffOffset`.

## [0.1.12] - 2026-11-18

### Added
- The Quest gate explains which working-tree changes block it, and permission
  reports identify the foreground Android user
  ([#173](https://github.com/abominableenterprise/yetikit/pull/173),
  [#160](https://github.com/abominableenterprise/yetikit/pull/160)).

### Fixed
- Release worktree cleanup preserves concurrent checkout and ref changes;
  gate and build verify that prepared worktrees still match the intended commit
  ([#111](https://github.com/abominableenterprise/yetikit/pull/111),
  [#143](https://github.com/abominableenterprise/yetikit/pull/143),
  [#163](https://github.com/abominableenterprise/yetikit/pull/163)).
- Linux Unity cleanup protects shared files when live editors or helpers cannot
  be ruled out, handles non-root runners, and returns seats before locked Git cleanup
  ([#119](https://github.com/abominableenterprise/yetikit/pull/119),
  [#122](https://github.com/abominableenterprise/yetikit/pull/122),
  [#127](https://github.com/abominableenterprise/yetikit/pull/127),
  [#150](https://github.com/abominableenterprise/yetikit/pull/150),
  [#167](https://github.com/abominableenterprise/yetikit/pull/167),
  [#170](https://github.com/abominableenterprise/yetikit/pull/170)).
- Interrupted Quest releases preserve recovery state and retain locks when
  worker exit is uncertain; performance cancellation still attempts proximity restoration
  ([#152](https://github.com/abominableenterprise/yetikit/pull/152),
  [#156](https://github.com/abominableenterprise/yetikit/pull/156),
  [#159](https://github.com/abominableenterprise/yetikit/pull/159)).
- Quest installs and crash rollbacks use the same per-device transaction;
  launch verdicts stay conservative when process checks or logs are incomplete
  ([#135](https://github.com/abominableenterprise/yetikit/pull/135),
  [#148](https://github.com/abominableenterprise/yetikit/pull/148)).
- Quest release reports distinguish per-device outcomes, cancellations, and
  install provenance failures. Follow-up commands and `wait` use the right
  release outcome even when runs reuse a report directory
  ([#125](https://github.com/abominableenterprise/yetikit/pull/125),
  [#129](https://github.com/abominableenterprise/yetikit/pull/129),
  [#145](https://github.com/abominableenterprise/yetikit/pull/145),
  [#168](https://github.com/abominableenterprise/yetikit/pull/168),
  [#174](https://github.com/abominableenterprise/yetikit/pull/174)).
- Quest performance reports retain combined timing when one component mean is
  missing and remove stale single-device summaries before list captures
  ([#113](https://github.com/abominableenterprise/yetikit/pull/113),
  [#154](https://github.com/abominableenterprise/yetikit/pull/154)).
- Android APK checks cover permission declaration variants and resolve exported
  launcher booleans. Quest log counts match literal tags
  ([#139](https://github.com/abominableenterprise/yetikit/pull/139),
  [#162](https://github.com/abominableenterprise/yetikit/pull/162),
  [#171](https://github.com/abominableenterprise/yetikit/pull/171)).
- Ship selects tests from literal paths, includes changed headless fixtures,
  and tightens test selection and retry evidence
  ([#121](https://github.com/abominableenterprise/yetikit/pull/121),
  [#123](https://github.com/abominableenterprise/yetikit/pull/123),
  [#124](https://github.com/abominableenterprise/yetikit/pull/124),
  [#157](https://github.com/abominableenterprise/yetikit/pull/157)).
- Offline fixtures isolate caller state, wait for complete PID records, and
  preserve failure and leak evidence when process inspection is incomplete;
  rollback coverage includes process disappearance without crash logs
  ([#114](https://github.com/abominableenterprise/yetikit/pull/114),
  [#115](https://github.com/abominableenterprise/yetikit/pull/115),
  [#136](https://github.com/abominableenterprise/yetikit/pull/136),
  [#138](https://github.com/abominableenterprise/yetikit/pull/138),
  [#141](https://github.com/abominableenterprise/yetikit/pull/141),
  [#164](https://github.com/abominableenterprise/yetikit/pull/164)).
- Vendoring fetches the exact tag, copies raw Git blobs, and restores Ship if
  installation fails before the package manifest is replaced
  ([#131](https://github.com/abominableenterprise/yetikit/pull/131)).

### Behaviour changes
- Quest doctor stays read-only, and the release gate requires evidence that at
  least one test passed before deployment
  ([#133](https://github.com/abominableenterprise/yetikit/pull/133)).
- PR verification avoids duplicate broad Ship test runs
  ([#134](https://github.com/abominableenterprise/yetikit/pull/134)).

### Adapter changes
- Use dedicated uppercase environment variable names in Quest signing config.
  Rename mappings that collide with shell or runner settings or overlap with
  release-note or previous-commit variables
  ([#117](https://github.com/abominableenterprise/yetikit/pull/117),
  [#165](https://github.com/abominableenterprise/yetikit/pull/165)).
- If an existing shared Unity cleanup lock is private, grant runner accounts
  read access in place. Move an old prepared Library without a completion
  marker aside and rerun `prepare`. Use unambiguous `quest.launchLogTags` and
  install `flock` for vendoring; see the updated [Ship](Tools/ship/README.md)
  and [vendor](Tools/vendor/README.md) guides.

## [0.1.11] - 2026-11-18

### Added
- Bracket live Quest performance captures with `perf start` and `perf stop`,
  without relaunching the app or clearing logcat ([#87](https://github.com/abominableenterprise/yetikit/pull/87)).
- Report detectable cgroup OOM evidence after an editor SIGKILL and include XML
  test counts in stage logs ([#93](https://github.com/abominableenterprise/yetikit/pull/93)).
- Opt into changed-fixture selection for the pure PR pass with `tests.prPure`;
  the full pure pass remains the default ([#94](https://github.com/abominableenterprise/yetikit/pull/94)).
- Opt into `cleanup --discard-noise` to remove release worktrees containing
  only recognized, unstaged editor noise ([#96](https://github.com/abominableenterprise/yetikit/pull/96)).
- Count configured `quest.launchLogTags` without changing the launch verdict,
  and use globs as well as exact paths for APK asset checks ([#108](https://github.com/abominableenterprise/yetikit/pull/108)).

### Fixed
- Quest release timeouts reap descendant processes ([#83](https://github.com/abominableenterprise/yetikit/pull/83)).
- Android setup refuses to replace an in-use Unity installation or proceed
  when it cannot verify the installation is idle ([#84](https://github.com/abominableenterprise/yetikit/pull/84)).
- Quest performance capture uses bounded timing and preserves recovery state
  for failed proximity restoration ([#85](https://github.com/abominableenterprise/yetikit/pull/85)).
- Ship reports paths that work after vendoring, accepts digits, underscores and
  hyphens in scene area names, and reads historical install baselines without
  relying on current configuration ([#105](https://github.com/abominableenterprise/yetikit/pull/105)).

### Behaviour changes
- Adopt the repository's dev-velocity policy and normalize Git attributes ([#78](https://github.com/abominableenterprise/yetikit/pull/78)).
- Retry recognized transient Git failures with bounded attempts and give the
  Quest doctor one serial-scoped reconnect within its device-check deadline ([#98](https://github.com/abominableenterprise/yetikit/pull/98)).

### Adapter changes
- Correct unknown `noise` keys and invalid regexes before upgrading; Ship now
  rejects them on load. See the updated [adoption notes](ADOPTION.md#ship) for
  supported configuration examples ([#104](https://github.com/abominableenterprise/yetikit/pull/104)).
- Optionally set `noise.artRoot` and `quest.backupPrefix`. To report on-device
  permission grants after install or rollback, list the required permissions in
  `quest.launcherChecks.permissions`; the former implicit microphone probe is
  no longer run ([#106](https://github.com/abominableenterprise/yetikit/pull/106)).

## [0.1.10] - 2026-11-10

### Added
- Quest performance reports include combined CPU&GPU frame time and CPU/GPU
  utilisation means when available, with full precision in JSON.
- Regression coverage for real-device VrApi telemetry and unrounded gate boundaries.

### Fixed
- Quest performance summaries label thermal sensors, omit zero second-sensor
  readings, round report-only values, and hash the installed base APK with
  timeboxed queries (or report unavailable).
- Document that performance capture clears earlier logcat after warm-up.

### Behaviour changes
- Summary text only; gates unchanged.

### Adapter changes
- None.

## [0.1.9] - 2026-11-10

### Added
- None.

### Fixed
- Quest launch no longer mistakes an OS-blocked launch or a process that never
  started without attributed crash evidence for a confirmed crash.

### Behaviour changes
- Blocked/never-started launches report INFRA (exit 3) and never roll back;
  package-attributed crashes/ANRs and observed processes that disappear remain
  CRASH (exit 1).

### Adapter changes
- None.

## [0.1.8] - 2026-11-09

### Added
- None.

### Fixed
- Quest performance capture waits for a cold-started app's unique PID before
  warm-up, while retaining identity and foreground checks.
- Proximity restoration is timeboxed during capture cleanup and cancellation;
  failed restoration records a manual recovery warning without blocking final
  results or lock release. Successful retries clear their matching marker.
- Ship test fixtures work from a consumer-owned vendored path.
- Process leak assertions explicitly skip when process inspection is unavailable.
- Tooling text has no trailing whitespace or blank lines at EOF, enforced by CI.

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
