# AGENTS.md

## Project overview

YetiKit is a public MIT Unity kit for Quest VR and mobile games. It contains
shared packages, documentation and a minimal Unity test Host, not game code.

## Public-repo rules

- No game names, studio-internal product names or people's names anywhere in
  repo text, code, comments, commit messages or PR text. Say "a consumer game"
  or "the first game". Keep private provenance in the consumer's private repo.
- No secrets, keys, endpoints, real playtest recordings, photos or voice in the
  repo. Test fixtures are synthetic. Never copy private source paths into docs.

## Layout and implementation

- Packages: `Packages/com.abominable.yetikit.<module>/{Runtime,Editor,Tests}`.
- Shell tooling: `Tools/ship/`; mesh checks: `Tools/art/`.
- Run Unity only through `Tools/ship/linux-unity.sh` (it holds the per-run seat lease); never activate the editor directly.
- `Host/` is the Unity test project using local package references.
- One asmdef per module, `autoReferenced: false`; no kit asmdef ever references a game.
- Moved scripts keep their original `.cs.meta` GUID; change only the namespace
  to `YetiKit.<Module>`. Do not generate replacement GUIDs during extraction.
- Dev-only modules (playtest, lab) are define-constrained by `YETIKIT_DEV`.
- Keep it thin: no reflection magic, no speculative extensibility.
- Pin every kit package at one tag. Fix upstream, never edit vendored or package
  code in a game; bump with `kit-bump.sh` when that tool is available.
- Commit Unity-generated folder/asmdef metadata and preserve extracted script metadata.

## Review and merge

- Small, modular code: one job per file; no source file over ~800 lines / 50 KB; new features in new modules.
- Small PRs: one area, about 500 changed lines or fewer (tests and pure moves excluded). Split bigger work into parts
  ("Part of #N"). Never widen a PR during review. Push after every commit. Bug fixes come with a failing-first test.
- Normal PRs run focused tests (including relevant slow files), `Tools/ship/test-all.sh --changed`, and
  `Tools/vendor/tests/run.sh`. Changed selection is broad quick-test coverage, not a precise dependency graph.
  Run `Tools/ship/tests/run.sh` locally only for release PRs (version bump/tag) or shared test-infrastructure
  changes (`tests/lib/`, `tests/run.sh`, fixtures). CI still runs the full suite.
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
hub-secret-limit: Unity Seat A=2
hub-secret-limit: Unity Seat B=2
hub-secret-lease: per-run
