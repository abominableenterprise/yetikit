# <Area>

Adoption template: all paths below are placeholders, not existing game implementation.
Scope: <one responsibility>; excludes: <neighboring areas>.

## Entry points and key files
| Role | Placeholder path | Responsibility |
| --- | --- | --- |
| Entry point | `Assets/Game/Features/<Area>/<Entry>.cs` | <caller and lifecycle> |
| Assembly | `Assets/Game/Features/<Area>/Game.<Area>.asmdef` | <explicit dependencies> |
| Prefab / catalog | `Assets/Game/Features/<Area>/<Asset>` | <serialized configuration> |
| Composition root | `Assets/Game/Bootstrap/CompositionRoot.cs` | <hook registration/disposal only> |

## Tests
- Focused tests/filter: `Assets/Game/Tests/<Area>/` / `<Area>Tests` (placeholders).
- Small test scene/builder: `Assets/Game/Tests/<Area>/<Area>Sandbox` (placeholder).
- Record invariants, a synthetic failure fixture and the expected result here; bugs start with a failing test.

## Where to start
- Behavior bug: entry point → focused failing test → smallest fix.
- Content change: prefab/catalog → area builder → focused scene validation; never edit scene YAML.
- Kit issue: synthetic reproduction → upstream fix/tag → coherent consumer bump; never patch vendored code.
- Add actual callers, ownership, teardown and exact focused test command when adopting this map.
