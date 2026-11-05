# Task brief tail

## Read and scope
- Read `AGENTS.md`; search only your area's `docs/CODEMAP.md` index entry and open that map.
- Batch searches/reads; get to code within 15 minutes. Keep files small, use named constants, write failing-first bug tests.
- If delegating, pass exact files, constraints and focused test command inline; no Unity runs unless explicitly assigned.
- Consumer tooling lives in `Tools/yetikit/`. These commands are planned, not shipped: [planned API, see docs/design.md](https://github.com/abominableenterprise/yetikit/blob/main/docs/design.md).
- Confirm adopted scripts/options exist before use; if absent, report blocked validation, not a successful run. Never edit vendored tools.

## Unity work on Linux
- Read the consumer's Unity quickstart if present; consult detailed docs only as needed.
- Reserve a deadline budget of at least 30 minutes + 2× the expected full-suite duration; do not start work that cannot fit.
- On a large VM, request ONE credential item for the run; never print credentials or split requests across multiple items.
- Run `Tools/yetikit/linux-unity.sh setup` and `Tools/yetikit/linux-unity.sh activate` once each per run, only when Unity is needed.
- Then use plain `Tools/yetikit/linux-unity.sh` commands. Keep one licensed session for probes; no repeated activation.
- Call `Tools/yetikit/linux-unity.sh return` exactly ONCE at the end of Unity work; review-only work must hold no Unity seat.
- Never use return traps, subshell wrappers, or `UNITY_RETURN_ON_EXIT`; never use `pkill -f` or `while pgrep -f`.
- Run long steps in the background with a log; wait using `wait-log <log> "<pattern>" <minutes>` or `wait-log --pid <pid>` (planned), not process-name polling.
- Iterate with a focused `-testFilter`; unknown-cause probes share ONE Unity session, one focused hypothesis at a time.
- Use `Tools/yetikit/linux-unity.sh scene --area <Area>` (planned) for small area scenes; no whole-game regeneration or lightmap changes.
- Run `Tools/yetikit/linux-unity.sh test pr` ONCE at the end, with at least 45 minutes left and enough time for the run. No git commands while it runs.
- Use only an existing documented known-flake policy; report exclusions explicitly, never silently ignore new failures.

## Shell checks and time limits
- Only if adopted scripts exist: iterate with `Tools/yetikit/test-all.sh --changed` or a focused test name.
- Run the full shell suite ONCE at the end; no extra full-suite variants unless requested. Report missing scripts as not run.
- Push WIP every 15–20 minutes when permitted and no Unity PR suite is running; never push credentials or media.
- Cap unknown-cause investigation at ~40 minutes; then push WIP, record hypotheses/evidence/blockers, and stop even without a fix.
- At the “About 15 minutes left” warning, start NO new full Unity or shell suite. Push, update the PR with what ran, and stop.
- Follow `AGENTS.md` review/merge rules without holding a Unity seat. Report cause, changes, test results/not-run reasons and PR link if any.
