# YetiKit

Shared, thin Unity building blocks for Meta Quest VR and mobile games, released
under the [MIT license](LICENSE). Proven features will be extracted incrementally
from a consumer game; gameplay, characters and scene policy stay in each game.
Version 0.3.6 adds a playtest recorder startup diagnostic and removes the
experimental label from in-app enrollment after verification with a secondary
Android profile. The kit supports playtest snaps (including capture before a
voice note), voice notes, upload transport and the optional XR recorder,
alongside a
[Worker/R2 inbox template](templates/playtest-worker/README.md),
a [new-game starter](templates/game/README.md) and a [Unity test Host](Host/README.md).

**Day 0:** install the [YetiKit skills](skills/README.md); copy [templates/game](templates/game/).

## Modules

| Module | Purpose | Status |
|---|---|---|
| [core](Packages/com.abominable.yetikit.core/README.md) | Build identity, release notes, performance counters, small utilities; no XR | available in 0.3.6 |
| [hands](Packages/com.abominable.yetikit.hands/README.md) | Tracked hands/controllers, shapes, panels, teleport and snap turn | available in 0.3.6 |
| [interaction](Packages/com.abominable.yetikit.interaction/README.md) | Carry, hand-off, release and throw rules | available in 0.3.6 |
| [playtest](Packages/com.abominable.yetikit.playtest/README.md) | Dev-only snaps, voice notes, session recording and uploads | available in 0.3.6 |
| [playtest.xr](Packages/com.abominable.yetikit.playtest.xr/README.md) | Dev-only XR recorder and hand sampling | available in 0.3.6 |
| [lab](Packages/com.abominable.yetikit.lab/README.md) | Dev-only experiments, live tuning and start panel | available in 0.3.6 |
| [quality](Packages/com.abominable.yetikit.quality/README.md) | Editor/test validators and synthetic fixtures | available in 0.3.6 |
| app.analytics | Allowed-event analytics | planned |
| app.telemetry | Crash reporting and privacy controls | planned |
| app.store | Purchases, ownership and restore | planned |
| app.ads | Mobile ads and Remove Ads | planned |
| app.review | Success-triggered review prompts | planned |
| app.sunset | Minimum-version checks and update notices | planned |
| app.menus | Shared menu/settings model, XR and screen-space renderers | planned |
| [Ship](Tools/ship/README.md) (shell tooling) | Headless builds, tests and Quest release safety | available in 0.3.6 |
| [vendor](Tools/vendor/README.md) | Atomic package pins and byte-for-byte Ship vendoring | available in 0.3.6 |
| [mesh checks](Tools/quality/README.md) | Static GLB/glTF/FBX quality checks | available in 0.3.6 |
| [skills/templates](skills/README.md) | Shared agent guidance and consumer adoption templates | available in 0.3.6 |

## Consumption

Install core and quality together in the consumer's `Packages/manifest.json`:

```json
{
  "dependencies": {
    "com.abominable.yetikit.core": "https://github.com/abominableenterprise/yetikit.git?path=/Packages/com.abominable.yetikit.core#v0.3.6",
    "com.abominable.yetikit.quality": "https://github.com/abominableenterprise/yetikit.git?path=/Packages/com.abominable.yetikit.quality#v0.3.6"
  }
}
```

A game's manifest must pin **every kit package in its dependency closure at the
same tag**, not just the top-level package: sibling Git packages do not resolve
from semver dependencies alone. Merge the entries above into an existing manifest;
retain its other dependencies. Playtest, playtest.xr and lab require
`YETIKIT_DEV` and are intended for development only.

Ship is not UPM: vendor the tagged `Tools/ship/` byte-for-byte into
`Tools/yetikit/`, with tag and digest in `VERSION`. Game-specific configuration
belongs in `yetikit.json`. From a kit checkout, update all pins and Ship together:

```sh
Tools/vendor/kit-bump.sh v0.3.6 --project /path/to/consumer --modules core,quality
Tools/vendor/kit-check.sh --project /path/to/consumer
```

Set `--modules` to a comma-separated selection of `core`, `quality`, `hands`,
`interaction`, `playtest`, `playtest.xr` and `lab`; the tool adds required kit dependencies.
Commit the manifest, vendored Ship tree and VERSION receipt together. See
[vendoring rules](Tools/vendor/README.md). Fix upstream; never patch a consumer's
vendored or package code.

## Target stack

Unity **6000.6.6f1**, URP, OpenXR + Meta OpenXR, XRI **3.6** and XR Hands.
Quest **3/3S** is the target, Quest **2** the performance floor, at **72 fps**.
Mobile app modules are non-XR; installing core must not pull XR dependencies.

See the [design](docs/design.md), [adoption playbook](ADOPTION.md),
[contribution rules](AGENTS.md) and [changelog](CHANGELOG.md).
CI checks shell syntax, package JSON, skill metadata, script metadata, GUID
uniqueness and assembly definitions. Run Unity tests with the [Host](Host/README.md).
Before tagging, follow the [kit release checklist](docs/release.md).
