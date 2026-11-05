# Day-0 adoption playbook

**Day 0:** install the [YetiKit skills](skills/README.md); copy [templates/game](templates/game/).

Runtime/tooling status: planned. No adoption commands or release tags are available yet.
Adopt in order: **Ship → core → quality → hands → interaction → playtest → lab → app.***.
Within app.*, start with analytics, telemetry and menus; add paid services only
when needed. A non-XR consumer skips hands, interaction and XR tooling.

**Fix upstream, never edit vendored or package code in a game; bump with `kit-bump.sh`.**
Each adoption PR must atomically pin the full dependency closure to one tag,
remove old scripts and their metadata, rewrite imports and add game adapters.
Run smoke + adapter tests, compare serialized inventory, then verify the installed
build. See [migration safety and day-0 evidence](docs/design.md).

## Ship
planned
## core
planned
## quality
planned
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
