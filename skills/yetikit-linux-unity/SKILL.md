---
name: yetikit-linux-unity
description: Run headless Unity safely on a large Linux task VM; use for compilation, focused tests or APK builds, not review-only work.
---
# Linux Unity task session

1. Read the game's agent rules, CODEMAP index and only your area guide. Use a
   **large VM** and lease **ONE Unity credential item** for the run; never echo
   credentials. Review-only rounds take **no Unity seat**.
2. Budget a deadline of **at least 30 minutes + 2× the suite estimate**. Start
   changing code within 15 minutes. Cap unknown-cause investigations at about
   40 minutes; then push WIP and a findings note, even without a fix.
3. Ship is planned in this skeleton; confirm the consumer has a tagged runner
   and read its help before using these consumer-side commands. Run
   `Tools/yetikit/linux-unity.sh setup` and `Tools/yetikit/linux-unity.sh activate`
   **ONCE**. Then use plain `open`, `test` or `apk` commands. The runner retains
   the licence/seat between commands and manages idle expiry.
4. Background long steps with a log; wait with `wait-log <log> '<pattern>' <minutes>`
   or `wait-log --pid <pid>`. Never use `while pgrep`, `pkill -f`, sleep-poll loops
   or per-command seat-return wrappers. Use the runner's stop command if supported.
5. Iterate with `Tools/yetikit/linux-unity.sh test editmode -testFilter <Namespace.Class>`.
   Use small per-area scenes; do not regenerate the full game or touch lightmaps
   for an isolated feature. Follow the installed runner's scene support.
6. Push WIP every **15–20 minutes**, except while a runner operation owns git.
   Run `Tools/yetikit/linux-unity.sh test pr` **once**, with **≥45 minutes left**;
   background it and wait as above. No git commands during that pass. Report
   actual XML totals and failures; a documented rerun is not a first-pass green.
7. After a 15-minutes-left warning, start no new full suite. Push and report what
   ran, what did not, and findings. Never hide throw, signing or release-audit
   failures in a flaky-test allowlist.
8. At the very end, even after failure, call `Tools/yetikit/linux-unity.sh return`
   **exactly once**. NEVER put return in an EXIT trap, a subshell wrapper or
   `UNITY_RETURN_ON_EXIT`. Do not return between probes.
