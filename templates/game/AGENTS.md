# AGENTS.md

## Overview
- Game: `{{GAME_NAME}}`; application ID: `{{GAME_ID}}`. Unity consumer of YetiKit.
- These are adoption templates, not an existing game implementation. Replace path placeholders during adoption.
- Kit APIs/tools below are planned, not shipped: [planned API, see docs/design.md](https://github.com/abominableenterprise/yetikit/blob/main/docs/design.md).
- Keep private identity, provenance, credentials, device identifiers and real playtest media out of public repositories; use synthetic fixtures.

## Find and change code
- Search only the relevant index entry in `docs/CODEMAP.md`; open only that area's map, not every map.
- Start writing code within 15 minutes of reading; if blocked, report the missing map/entry point instead of browsing indefinitely.
- Update the area's map when adding/moving key files; add an index row for a new area.
- Use feature asmdefs with explicit dependencies and `autoReferenced: false`; no kit assembly references game code.
- Prefer prefabs and catalogs; never hand-edit scene YAML. Use small per-area test scenes and their builders, not whole-game regeneration; leave lightmaps alone.
- One job per file, named constants, no speculative abstractions. Bugs require a failing-first regression test.
- Register kit hooks only in the composition root, with disposable lifetimes. Dev code belongs only in `Game.Dev`, constrained by `YETIKIT_DEV`; release must not reference it.
- Fix kit defects upstream; never edit `Tools/yetikit/` or installed kit packages. Use `kit-bump.sh` (planned) to update vendored tools and all kit dependency pins coherently to one tag.

## Review and merge

- Small, modular code: one job per file; no source file over ~800 lines / 50 KB; new features in new modules.
- Small PRs: one area, about 500 changed lines or fewer (tests and pure moves excluded). Split bigger work into parts
  ("Part of #N"). Never widen a PR during review. Push after every commit. Bug fixes come with a failing-first test.
- Reviewer: Check Norris (`checknorrisbot[bot]`, status `checknorris`, green only at 5/5). It reviews ~10 quiet minutes
  after the last push (never push empty commits to trigger it). Commands: `@checknorrisbot review`,
  `@checknorrisbot re-review`, `@checknorrisbot rescore`.
- Findings (reply in the thread, mention first, one reply per thread):
  - real P0/P1: fix with a test, `@checknorrisbot Fixed in <sha> (<what changed>)`;
  - false positive: explain citing code (the only reply that clears a P0/P1 besides an owner risk acceptance);
  - minor P2: fix if small, else `@checknorrisbot Deferred to #N: <why minor>` into one `follow-up` issue per PR
    (`Follow-ups from #<PR>: <title>`). Answer every P2 before pushing again.
  - Resolve each thread after its verdict.
- **Merge without asking** when, on the current head commit, `checknorris` is green, every review thread is resolved
  and all checks are green: `gh pr merge <n> --merge --match-head-commit <sha>`.
  Never force-push shared branches, never `--delete-branch`.

## The Robots automation (ignore unless you are running inside a The Robots task)

hub-merge: on
hub-merge-requires: checknorris
hub-secret-lease: per-run
