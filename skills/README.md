# Shared agent skills

Install these in the **game bot**, before its first task. Call `install_skill`
with repository `abominableenterprise/yetikit` and path `skills/<name>` (one
call per skill, using the bot platform's argument names). Installed skills
update automatically; do not maintain private copies. Review updates alongside
the game's pinned kit capabilities: a skill is guidance, not an API upgrade.

| Skill | Use when |
| --- | --- |
| [yetikit-linux-unity](yetikit-linux-unity/SKILL.md) | Compiling, testing or building on a large Linux Unity VM |
| [yetikit-quest-install](yetikit-quest-install/SKILL.md) | Safely installing, verifying and launching on a Mac-attached Quest |
| [yetikit-add-prop](yetikit-add-prop/SKILL.md) | Adding grabbable/throwable content and its grip/replay checks |
| [yetikit-add-tunable](yetikit-add-tunable/SKILL.md) | Exposing persistent, captured in-headset feel controls |
| [yetikit-add-experiment](yetikit-add-experiment/SKILL.md) | Giving one development question a prefab and direct boot route |
| [yetikit-asset-intake](yetikit-asset-intake/SKILL.md) | Taking a concept through modeling, conversion and visual checks |
| [yetikit-playtest-triage](yetikit-playtest-triage/SKILL.md) | Handling snaps and session analysis without noisy clean reports |

Copy [templates/game](../templates/game/) for game-owned agent rules, CODEMAP,
task-brief tail, review checklist and playtest-inbox routine. Replace
`{{GAME_NAME}}` and `{{GAME_ID}}`, fill area paths/commands, and configure private
sources and permissions outside the public kit. No stamping script ships yet.

Runtime APIs, quality validators, Ship and analyzer remain planned; see
[the design](../docs/design.md). Skills explicitly label these boundaries and
must not be read as proof an unavailable command ran successfully.

Validate without Unity: `python3 -m pip install PyYAML==6.0.2`, then run
`python3 -m unittest discover -s Tools/skills -p 'test_*.py' -v` and
`python3 Tools/skills/validate.py` from the repository root.
