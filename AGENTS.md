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

## Dev velocity (from factory-kit; change it by PR there)

- FINAL message, first line exactly one of:
  - `RESULT: DONE <PR link>` (add `review stuck: <why>` if the review did not reach 5/5)
  - `RESULT: NOTHING TO DO <why>`
  - `RESULT: BLOCKED-INFRA <exact error>`
  - `RESULT: BLOCKED-OWNER <question>`
- Do only the issue in the brief. One concern per PR, ≤500 changed production lines, tests in the same PR. Branch from main.
- Small, modular code: one job per file; no source file over 800 lines or 50 KB; new features in new modules.
- Never widen a PR during review. Push after every commit.
- No new follow-up work issues except one `Follow-ups from #<PR>` issue (label `follow-up`, never `ready`) for code-workflow's `Deferred to #N`. Other work goes in the PR description for owner approval.
- WRITE BUDGET: The hub allows about 100 GitHub issue writes per day. Post at most one comment per task result
  on its issue; set labels when creating an issue, not in separate edits. Keep running detail in GOAL Log
  or local files, not GitHub comments. When budget is low, filing new ready issues takes priority over comments.
  A task VM may create an issue it needs with `gh` as part of its own repo work, within the issue-scope rule above.
- Bug fix: reproduce first (a fixture from docs/debug.md, or exact steps), add a failing regression test where feasible, then fix.
  Hardware-only bugs: put repro steps and device evidence in the PR instead of a fake test.
- PR body: when fixing a bug introduced by an earlier PR, put `Regression from #N` or `Regression from owner/repo#N` alone on a line.
  For reverts, use `Reverts owner/repo#N` or GitHub's default `This reverts commit <sha>.` line.
  One line per link, no other words on that line; the parser is strict.
- UI PRs: a fresh simulator, browser or editor screenshot (≤768 px wide, at most 2) with the SHA and fixture name.
  Physical-device evidence is for batched candidates only; write "device: pending candidate". Non-visual PRs: list the tests that ran.
- Verify: run focused tests for touched code while iterating. Before opening a PR and the final push,
  run the selected gate below and check the PR is <=500 changed production lines; list commands and
  results in the PR body. Keep the existing .github/workflows; add no new GitHub-hosted Actions.
- GATE SCOPE: A PR changing only docs or policy text (no code, build, test, or fixture files)
  runs the repo's short lint/format gate (`python3 -B Tools/ci/check-unity.py && python3 -B Tools/ci/check-whitespace.py && python3 -B Tools/skills/validate.py`, plus `bash -n` on each changed shell script) instead of the full gate. Its PR body must state
  "Coverage: docs-only, full gate not run".
  - Run one broad gate per checkout; never run two broad suites at once in the same checkout.
  - For ordinary PRs, the broad gate is only `Tools/ship/test-all.sh --changed` plus
    `Tools/vendor/tests/run.sh`, run sequentially. Add the full `Tools/ship/tests/run.sh` suite only
    for release PRs (version bump/tag) or shared test-infrastructure PRs, and only if the changed run
    did not already cover every Ship test.
  - If `--changed` reports `[shell-test] passed N files` and N equals the number of
    `Tools/ship/tests/*.test.sh` files, cite that run as the full Ship receipt; do not rerun
    `Tools/ship/tests/run.sh`.
  - Background long suites and wait once with `wait-log --pid <pid> <minutes>` or the job completion
    notice. Read the summary once after completion; do not repeatedly tail or grep for status.
- FULL-GATE TIMEOUT: Use at least 900s, or the repo's documented cold-start time if larger;
  prove the test worker started before counting a result (retain its startup log). 0 tests run is not a pass.
  A timeout with no result file (e.g. JUnit XML) is infra/no-result: never a test failure,
  never counts toward remediation-failure limits. Allow at most one retry with a longer timeout;
  a second no-result timeout triggers DISPATCH's INFRA COOLDOWN. Report BLOCKED-INFRA, not a failed test.
  Retain timeout, startup evidence, result-file presence and retry count across wakes/tasks in GOAL Log.
- Unity work runs only through `Tools/ship/linux-unity.sh`; a Unity test pass requires successfully parsing the results XML with `testcasecount>0`.
- Reviewer: Check Norris (`checknorrisbot[bot]`, status `checknorris`, green only at 5/5). It reviews ~10 quiet minutes
  after the last push (never push empty commits to trigger it). Commands: `@checknorrisbot review`,
  `@checknorrisbot re-review`, `@checknorrisbot rescore`.
- Answer every checknorris finding in its own thread: `Fixed in <sha>`, `False positive: <file:line>`, or `Deferred to #N`.
  After 3 rounds without 5/5, stop and report `RESULT: DONE <PR> review stuck: <why>`.
- Findings (reply in the thread, mention `@checknorrisbot` first, one reply per thread):
  - real P0/P1: fix with a test, `@checknorrisbot Fixed in <sha> (<what changed>)`;
  - false positive: `@checknorrisbot False positive: <file:line> (<why>)` (the only reply that clears a P0/P1 besides an owner risk acceptance);
  - minor P2: fix if small, else `@checknorrisbot Deferred to #N: <why minor>` into the one `Follow-ups from #<PR>` issue.
    Answer every P2 before pushing again.
  - Resolve each thread after its verdict accepts the reply or confirms the fix.
- After the push and the answers, END. The hub merges at 5/5. No polling, sleeps or pr-wait.
- Never force-push shared branches, never `--delete-branch`.
- Probing is capped at about 40 minutes. Write findings to `docs/investigations/<slug>/STATE.md`.
- Debug and test hooks compile only into dev/internal builds and never bypass production auth.
- Never log secrets, tokens, typed text or personal data. Never commit secrets or large generated files. Never print secrets.

## The Robots automation (ignore unless you are running inside a The Robots task)

hub-merge: on
hub-merge-requires: checknorris
hub-followups-max: 1
hub-followups-size: large
hub-secret-limit: Unity Seat A=2
hub-secret-limit: Unity Seat B=2
hub-secret-lease: per-run
