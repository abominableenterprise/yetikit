# Day-0 adoption playbook

**Day 0:** install the [YetiKit skills](skills/README.md); copy [templates/game](templates/game/).

Runtime packages remain planned. Ship and consumer vendoring tooling are available;
choose an existing release tag before adopting.
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
/path/to/yetikit/Tools/vendor/kit-bump.sh v0.1.0 --project /path/to/consumer --modules core,hands
/path/to/yetikit/Tools/vendor/kit-check.sh --project /path/to/consumer
```

The tag above is illustrative. Bump replaces the vendored Ship tree and pins all
selected packages plus their dependency closure at one tag. Commit the Ship copy,
VERSION receipt and consumer manifest together. See [vendoring usage and rules](Tools/vendor/README.md)
for offline sources, CI checks and the debugging-only `file:` override.

## Ship
See [Ship tooling](Tools/ship/README.md).
## core
planned
## quality
Add [editor validators](Packages/com.abominable.yetikit.quality/README.md) to consumer EditMode tests and opt into the release build audit.
Run the [mesh quality checks](Tools/quality/README.md) on changed GLB/glTF/FBX assets in CI before importing or shipping art.
## hands
planned
## interaction
planned
## playtest
planned
## lab
planned
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
