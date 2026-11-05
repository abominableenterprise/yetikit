# YetiKit

Shared, thin Unity building blocks for Meta Quest VR and mobile games, released
under the [MIT license](LICENSE). Proven features will be extracted incrementally
from a consumer game; gameplay, characters and scene policy stay in each game.
The first implemented module is [core](Packages/com.abominable.yetikit.core/README.md),
with a minimal [Unity test Host](Host/README.md). Other modules remain planned.

**Day 0:** install the [YetiKit skills](skills/README.md); copy [templates/game](templates/game/).

## Modules

| Module | Purpose | Status |
|---|---|---|
| core | Build identity, release notes, performance counters, small utilities; no XR | 0.1.0-pre |
| hands | Tracked hands/controllers, shapes, panels, teleport and snap turn | planned |
| interaction | Grab, carry, hand-off, release and throw | planned |
| playtest | Dev-only capture, durable outbox, optional photo/voice and upload | planned |
| lab | Dev-only experiments, live tuning and start panel | planned |
| quality | Editor/test validators and synthetic fixtures | planned |
| app.analytics | Allowed-event analytics | planned |
| app.telemetry | Crash reporting and privacy controls | planned |
| app.store | Purchases, ownership and restore | planned |
| app.ads | Mobile ads and Remove Ads | planned |
| app.review | Success-triggered review prompts | planned |
| app.sunset | Minimum-version checks and update notices | planned |
| app.menus | Shared menu/settings model, XR and screen-space renderers | planned |
| Ship (shell tooling) | Headless builds and tests | [implemented](Tools/ship/README.md) |

## Consumption

Git UPM URL pattern:
<https://github.com/abominableenterprise/yetikit.git?path=/Packages/com.abominable.yetikit.<module>#vX.Y.Z>

A game's manifest must pin **every kit package in its dependency closure at the
same tag**, not just the top-level package: sibling Git packages do not resolve
from semver dependencies alone. Package version `0.0.1` is a skeleton marker,
not a release promise. Core is `0.1.0-pre`; use the Host for local validation.
No release tag is provided yet.

Ship is not UPM: vendor the tagged `Tools/ship/` byte-for-byte into
`Tools/yetikit/`, with tag and digest in `VERSION`. Game-specific configuration
belongs in `yetikit.json`. The planned `kit-bump.sh` updates all pins and Ship
together. Fix upstream; never patch a consumer's vendored or package code.

## Target stack

Unity **6000.6.6f1**, URP, OpenXR + Meta OpenXR, XRI **3.6** and XR Hands.
Quest **3/3S** is the target, Quest **2** the performance floor, at **72 fps**.
Mobile app modules are non-XR; installing core must not pull XR dependencies.

See the [design](docs/design.md), [adoption playbook](ADOPTION.md),
[contribution rules](AGENTS.md) and [changelog](CHANGELOG.md).
CI checks shell syntax, package JSON, skill metadata, script metadata, GUID
uniqueness and assembly definitions. Run Unity tests with the [Host](Host/README.md).
