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
- Editor cleanup only signals editors and helpers carrying the current runner's
  ownership marker, protecting editors started outside that run
  ([#28](https://github.com/abominableenterprise/yetikit/issues/28)).

### Behaviour changes
- Foreign editors are no longer killed by runner cleanup. Shared-memory and
  project lockfile removal is skipped with a warning while any editor remains.

### Adapter changes
- None.

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
