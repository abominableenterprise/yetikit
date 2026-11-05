# Changelog

All notable changes are documented here in Keep-a-Changelog style.
Every release must include **Added / Fixed / Behaviour changes / Adapter changes**
(what a consumer game must edit), even if a section says "None".
Before 1.0, minor releases may break compatibility only with explicit adapter
notes. Chunk and tuning schema changes count as breaking changes too.

## [Unreleased]

### Added
- Public skeleton, planned package manifests, adoption/design docs and seat-free CI.
- Shared build identity, release notes and performance utilities, with a minimal test host.
- Licence-free checks for Unity script metadata and assembly references.

### Fixed
- None.

### Behaviour changes
- Build headers use the consumer's product name; build notes use kit-neutral environment variables.

### Adapter changes
- Consumers opt into the core runtime/editor assemblies and wrap builds in a build-stamp scope.
  See the core README for setup. Other modules remain planned; no release tag exists yet.
