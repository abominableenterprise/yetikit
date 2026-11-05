# Code map index

Adoption placeholders only: none of these paths asserts an existing game implementation.
Search this small index for your area, then read only its map. Add a row when adopting an area.
Kit integrations are [planned API, see docs/design.md](https://github.com/abominableenterprise/yetikit/blob/main/docs/design.md), not shipped.

| Area | Area map (placeholder) | Starting point (placeholder) |
| --- | --- | --- |
| Bootstrap / kit hooks | `docs/codemap/bootstrap.md` | `Assets/Game/Bootstrap/CompositionRoot.cs` |
| Gameplay feature | `docs/codemap/<area>.md` | `Assets/Game/Features/<Area>/` |
| Dev / playtest | `docs/codemap/dev.md` | `Assets/Game/Dev/` (`Game.Dev`, `YETIKIT_DEV`) |

Create each map from [`codemap/_area-template.md`](codemap/_area-template.md).
Find the entry point and a focused test within 15 minutes; report missing navigation instead of reading everything.
