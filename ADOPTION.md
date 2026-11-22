# Day-0 adoption playbook

**Day 0:** install the [YetiKit skills](skills/README.md); copy [templates/game](templates/game/).

Version 0.2.0 provides core, quality, hands, interaction, playtest and lab,
plus Ship, consumer vendoring, mesh checks and the new-game starter. Playtest
and lab are development-only; app modules remain planned.
Adopt in order: **Ship → core → quality → hands → interaction → playtest → lab → app.***.
Within app.*, start with analytics, telemetry and menus; add paid services only
when needed. A non-XR consumer skips hands, interaction and XR tooling.

**Fix upstream, never edit vendored or package code in a game; bump with `kit-bump.sh`.**
Each adoption PR must atomically pin the full dependency closure to one tag,
remove old scripts and their metadata, rewrite imports and add game adapters.
Run smoke + adapter tests, compare serialized inventory, then verify the installed
build. See [migration safety and day-0 evidence](docs/design.md).

## Adopting / upgrading

Use a kit checkout to update a consumer before Unity resolves packages:

```sh
/path/to/yetikit/Tools/vendor/kit-bump.sh v0.2.0 --project /path/to/consumer --modules core,quality
/path/to/yetikit/Tools/vendor/kit-check.sh --project /path/to/consumer
```

Set `--modules` to a comma-separated selection of `core`, `quality`, `hands`,
`interaction`, `playtest` and `lab`. Bump replaces the vendored Ship tree and
pins all selected packages plus their dependency closure at one tag. Commit the
Ship copy, VERSION receipt and consumer manifest together. See
[vendoring usage and rules](Tools/vendor/README.md) for offline sources, CI checks
and the debugging-only `file:` override.

## Ship
See [Ship tooling](Tools/ship/README.md). Before setup on a fresh Linux VM,
install Go and use the pinned crane install command:

```sh
GOBIN="$HOME/bin" go install github.com/google/go-containerregistry/cmd/crane@v0.22.1
```

Setup also accepts a preinstalled crane on PATH or a configured archive; see
[Ship requirements](Tools/ship/README.md#vendor-into-a-game).

- For Quest releases, set `QUEST_CERT_SHA256` to the expected APK signing
  certificate fingerprint in the environment, not in `yetikit.json`. Set
  `QUEST_SERIAL` in the environment to select a headset, or leave it unset with
  exactly one headset attached.
- Static font cleanup is opt-in: list the exact project-relative font asset
  paths in `noise.fontAssetPaths`. Only list assets whose editor serialization
  changes can be discarded.
- Set the `SCENE_AREAS` environment variable to override the areas table from
  `scene.areasFile`.
- Use `tests.builderFixtures` to map exact builder paths to lists of fully
  qualified fixture names. A change to a mapped builder adds those fixtures to
  the Gfx selection for `test pr`.

## core
Reference the opt-in runtime/editor assemblies and wrap consumer builds in a
build-stamp scope. Follow the [core setup and build adapter example](Packages/com.abominable.yetikit.core/README.md).
## quality
Add [editor validators](Packages/com.abominable.yetikit.quality/README.md) to consumer EditMode tests and opt into the release build audit.
Run the [mesh quality checks](Tools/quality/README.md) on changed GLB/glTF/FBX assets in CI before importing or shipping art.
## hands
Use [hands](Packages/com.abominable.yetikit.hands/README.md) for tracked input and locomotion.
## interaction
Use [interaction](Packages/com.abominable.yetikit.interaction/README.md) for props and throw rules.
## playtest
Use [playtest](Packages/com.abominable.yetikit.playtest/README.md) for local session capture under `YETIKIT_DEV`.
## lab
Use [lab](Packages/com.abominable.yetikit.lab/README.md) for experiments and live tuning under `YETIKIT_DEV`.
## app.analytics
planned
## app.telemetry
planned
## app.menus
planned
## app.store
planned
## app.review
planned
## app.ads
planned
## app.sunset
planned
