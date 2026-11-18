# Ship: Unity build and Quest release tooling

Part of the Ship extraction. This toolset runs a consuming project's editor on
Linux with Xvfb/Mesa, without Docker or changes to its editor APIs. Shell tests
use a fake editor; the kit itself does not need a Unity installation to test.

## Vendor into a game

At a chosen kit tag, copy **the complete `Tools/ship/` directory**, byte for byte,
to the game's `Tools/yetikit/`. Commit it with a `Tools/yetikit/VERSION` file
containing the tag and SHA-256 digest of the copied bundle. Record the bundle's
hashing recipe with that digest (sorted relative paths and bytes, excluding
`VERSION`); a standardized vendoring/bump script and digest check come later.
Do not edit the vendored copy. Put project policy in root `yetikit.json` and fix
shared tooling upstream. All relative configuration paths are project-relative.
`PROJECT` overrides the root (otherwise two directories above the runner);
`YETIKIT_CONFIG` overrides the config file path.

Requirements: Linux, Bash 4+, `jq`, Git, GNU coreutils, util-linux (`flock`),
Perl, curl, tar, and Xvfb/xauth plus the editor runtime libraries. `setup` installs
the runtime libraries. Put `crane` on PATH (or in `$BIN_DIR`, default `$HOME/bin`)
first, or configure `setup.craneArchive` with an archive containing its Linux
x86-64 executable. If Go is installed, this pinned one-line command installs
crane into the default location (use your `$BIN_DIR` instead if overridden):

```sh
GOBIN="$HOME/bin" go install github.com/google/go-containerregistry/cmd/crane@v0.22.1
```

See the [pinned crane release](https://github.com/google/go-containerregistry/releases/tag/v0.22.1).
Setup prints the corresponding command with its actual install directory when
crane is missing; it does not silently download an unverified executable.

## Adopting / upgrading

Games vendor this with `Tools/vendor/kit-bump.sh`; see [vendoring and CI checks](../vendor/README.md).

## Licence lifecycle: once per session

```sh
Tools/yetikit/linux-unity.sh setup --android
Tools/yetikit/linux-unity.sh activate
Tools/yetikit/linux-unity.sh open
Tools/yetikit/linux-unity.sh test editmode
Tools/yetikit/linux-unity.sh return
```

Setup and activate once, use **plain commands** while iterating, then return once
at the end, including after failures. Do not wrap each command in return traps.
Never run with `bash -x`/`set -x`. Credentials are environment-only:
`UNITY_USERNAME`/`UNITY_PASSWORD`, falling back to `USERNAME`/`PASSWORD` when
needed. Licensing output is masked. A valid existing ULF is reused; a missing
or invalid one is reactivated. Return uses only the Licensing Client, never a
second CLI return. `UNITY_RETURN_ON_EXIT=1` is an opt-in one-shot lifecycle.

The hub seat lease is unchanged: `THEROBOTS_HUB_URL`, `THEROBOTS_TASK_ID`, and
`THEROBOTS_TASK_TOKEN` enable it. Without those variables or Unity credentials,
it is a no-op. Acquisition waits up to `UNITY_SEAT_WAIT_MINUTES` (90); successful
activation holds the seat between commands. Explicit/idle return releases it.
A detached watcher returns the licence after `UNITY_IDLE_RETURN_MINUTES` (10)
without activity. Active editor descendants are not idle. Coordination is per
canonical ULF path, shared across checkouts; secrets are never persisted.
Old checkout-local numeric-PID watcher upgrade bridges are intentionally omitted:
finish/return any pre-vendoring session before switching toolsets. Shared watcher
ownership, activation locks, and seat-retirement protections are retained.
Editor commands sharing `SHM_DIR` are serialized by a persistent cleanup lock:
an overlapping runner fails before starting an editor or deleting shared memory.
Wait for the active run or invoke `stop` from its checkout; never remove the lock
file while a run is active.

Cleanup removes stale `udsMem*`, `sem.udsMem*`, and the project's
`Temp/UnityLockfile` only after a complete scan finds no Unity processes. The
runner only removes entries it owns, even when running as root. A warning about
unverified ownership means those entries were kept; other runner-owned entries
can still be removed.

Task VMs can run as root; check the runner's effective UID with `id -u` (0 is
root). A root runner still skips the wipe if `/proc` inspection is incomplete.
A non-root runner may be unable to inspect even unrelated system daemons. If
that scan is incomplete and found no Unity process, cleanup retries the
read-only scan with `sudo -n` if permitted, without prompting or elevating file
deletion. Without that access, or if Unity classification is still uncertain
(such as a helper from a removed installation), the incomplete-inspection
warning means all shared files were kept. Use a runner with full process
visibility if stale files persist; do not delete them while another editor
could be using them. Setup still requires a complete privileged scan before
replacing an existing editor installation.

## Commands

| Command | Behaviour |
| --- | --- |
| `setup [--android] [--no-creds]` | Stream the versioned GameCI base/android image into `UNITY_ROOT` (default `/opt/unity`), install libraries and the `merge.ours` Git driver. `--no-creds` provisions without activation. An Android setup replaces a complete base-only install. |
| `activate` / `return` | Activate/reuse a Personal ULF licence; return once and release the seat. |
| `open [--keep [path]]...` | Compile/open without graphics. A cold project restores/saves the Library cache. |
| `test editmode [Unity args...]` | Pure pass (`!Gfx;!MacOnly`) without graphics, then Gfx on Xvfb. A caller's `-testFilter` may match either pass, but must execute tests overall. `EDITMODE_GFX=0` skips Gfx and requires executed pure tests; it is not needed for pure-only filters. |
| `test playmode [Unity args...]` | PlayMode tests on Xvfb. |
| `test pr [base] [Unity args...]` | Full pure pass by default (opt in to selection via `tests.prPure`), then only touched Gfx fixtures. The default base is `origin/main`. No caller `-testFilter`/`-testCategory`. |
| `scene [--keep path]... [--area Area]...` | Run configured generated-scene steps; optionally only configured area steps, then conservative noise cleanup. Without `scene`, explain that no generated scene is configured. |
| `lab [--keep [path]]...` | Run the optional `labMethod`; cleanup/`--keep` as in `open`. |
| `apk [dev\|release\|contest]` | Android build on Xvfb; `contest` is a compatibility alias for `release`. Print path, size and SHA-256; remove stale APK before building. |
| `cache-key [android]` | Bare SHA-256 of package manifest, lockfile, project editor version and configured Unity version; Android has its own key. |
| `cache-restore` / `cache-save` | Use external `task-cache` when available; missing service is a no-op, failed/timed-out restore falls back to cold import. |
| `stop` | Stop only this runner's recorded process tree/marked descendants, never a broad process-name kill. |
| `all` | Setup, activate, open, EditMode tests; retain the licence even on failure. Return once afterward. |

### Test evidence

Test commands reject forwarded `-quit`, `-testResults` (including its legacy
alias `-editorTestsResultFile`) and `-logFile` before starting an editor. The
runner owns these options and also rejects case variants, doubled dashes, and
`=value` forms without relying on whether a Unity version accepts them.

Each pass, including a known-flake retry, must write parseable result XML with
a `test-run` root and numeric `total`, `passed`, `failed` and `skipped` counts.
Missing/empty/invalid XML, zero total, or no passed/failed tests fails the pass
unless an empty pass is specifically allowed below.

Without a caller's category or name filter, `test editmode` requires tests in
its pure pass but allows the implicit Gfx pass to select zero tests. Other
constraints such as `-assemblyNames` narrow both passes without requesting
Gfx, so they don't change that rule. The Gfx pass of `test pr` may also select
zero tests. These passes log `no tests selected (Gfx categories); treated as
empty` when their valid results report zero tests.

For `test editmode -testFilter <filter>` without `-testCategory`, when both
passes run, either pass may select zero tests with valid XML. Each empty pass
logs the filter and category it did not match. The sum of executed tests
(`passed` + `failed`) across both passes must be greater than zero; otherwise
the command fails and names the filter. This never excuses missing/invalid XML,
all-skipped/ignored tests, editor failures, or an empty retry. Unfiltered pure,
PlayMode and explicitly selected category passes still must execute tests.
`EDITMODE_GFX=0` keeps its single-pass behaviour: filtered pure tests must execute.
A later evidence-only failure preserves an earlier editor's nonzero exit status.
Evidence validation uses Python 3's standard library.

For an explicit category, EditMode runs a single graphics-enabled pass; Gfx
gets its own timeout. A RenderTool class filter runs alone with `RenderTool`.
The legacy `-editorTestsCategories` and `-editorTestsFilter` spellings are
handled like `-testCategory` and `-testFilter`.
Known flakes are one fully qualified test or fixture per line, with `#` comments.
Only a pass consisting entirely of known failures reruns once. Both result XMLs
are retained and a successful retry prints `flaky-passed`, not an unqualified
first-pass success. Every original failed fullname, including each parameterized
case, must explicitly pass on retry; skipped or missing cases do not clear the
failure. Missing results/crashes are never flakes.

Every editor command (`open`, `test`, `apk`, `scene`, `lab`) cleans newly
introduced noise even after editor failure. Run cleanup covers material keyword,
prefab float and fixed-timestep formatting, plus explicitly configured static
font assets; `scene` also handles configured atlas repacks and bake-only lightmap
`platformSettings`. Dirty-before/staged files and `--keep` paths survive.
A bare `--keep` on open/test/lab skips cleanup. Exit **3** means editor/test work
succeeded but noise cleanup failed: rerun only the printed recovery command.
Standalone `scene-noise.sh [--run] [--before file] [--keep path]...` reads the
same project config. Avoid concurrent Git operations during cleanup.

Run one broad gate per checkout; never run two broad suites at once in the
same checkout. Background long suites, then wait once with
`wait-log --pid <pid> <minutes>` (an environment helper, not bundled here) or
use the job completion notice. Read the summary once after completion; do not
repeatedly tail or grep for status.

```sh
mkdir -p build
Tools/yetikit/linux-unity.sh test pr > build/test-pr.log 2>&1 &
wait-log --pid $! 25
```

Logs/results live in `build/` (`OUT_DIR` override). `test-stages.log` records
elapsed stage timing and the total, passed, failed and skipped counts from each
pass's result XML, including retries. When a direct editor run exits with
SIGKILL status, the runner also reports its cgroup v2 `memory.events` `oom`
and `oom_kill` counters and any measurable changes. The counters cover the
whole cgroup, so a change is a clue, not proof the editor was OOM-killed.
If the counters are unavailable, the usual kill and timeout diagnosis still
prints.
Default limits: `UNITY_TIMEOUT=1800`, `UNITY_GFX_TIMEOUT=3600`, `APK_TIMEOUT=5400`,
`TASK_CACHE_TIMEOUT=300` seconds. An explicit `UNITY_TIMEOUT` also sets Gfx unless
`UNITY_GFX_TIMEOUT` is supplied. PR Gfx selection caps at `TEST_PR_GFX_MAX=12`
fixtures and estimates a budget unless a timeout was explicitly set.

Android builds reserve `APK_MIN_FREE_GB=10` (warm Bee cache:
`APK_MIN_FREE_GB_WARM=4`), limit jobs via `APK_JOBS=2`, and best-effort add
`APK_SWAP_GB=3` swap when below `APK_SWAP_BELOW_GB=12` RAM with no swap. Set swap
to zero to disable. Swap is removed on exit. Other operational overrides include
`UNITY_ROOT`, `UNITY_IMAGE`, `UNITY_MODULES`, `BIN_DIR`, `CRANE_VERSION`, `ULF`,
`SHM_DIR`, `TASK_CACHE`, `PIDFILE`, `PIDFILE_FALLBACK`, `SEAT_STATE`,
`UNITY_RETURN_TIMEOUT`, `APK_SWAP_DIR`, `KNOWN_FLAKES`, `SCENE_AREAS`, `NOISE_BASE`,
`NOISE_GIT_TRIES` and `NOISE_GIT_DELAY`. These control environment/resources, not
game policy. A profile-based APK requires an installed Unity CLI as well.

### Opt-in pure selection for `test pr`

With `tests.prPure`, Ship selects changed EditMode fixtures, fixtures in the
EditMode areas of changed runtime C# files, and configured smoke fixtures. It
uses committed changes since the merge base, local tracked changes, and
untracked files. The pure category filter still applies. Gfx selection is
unchanged: changed runtime types search their area's tests; editor builders
search all tests.

Ship runs the full pure pass if selection is empty or exceeds the cap; it never
trims the list. Changes to the running Ship bundle, `Tools/yetikit/`,
`yetikit.json`, `Packages/`, `ProjectSettings/`, `.github/`, assembly definitions,
assembly references, response files or C# under `tests.editorRoot` also force
full pure. Use `fallbackRegex` to add project-specific paths, such as shared
fixture helpers or runtime files used across areas. Both selected fixtures and
full-pass reasons are written to `test-stages.log` when opted in. A selected
pure pass must still execute tests to pass.

Set `TEST_PR_PURE_ALL=1` to force full pure, or `TEST_PR_PURE_MAX` to override the
configured cap (decimal integer, zero forces full; invalid values also run
full). Neither variable enables selection without the config block.
`test editmode`, PlayMode and release testing are unaffected.

## `yetikit.json` schema 1

Required keys are `schema`, `unityVersion`, and `build`. Unknown keys are reserved
for future tools. Startup validates the config before credentials, seat leases,
or editor work, naming missing/invalid keys. Minimal execute-method example:

```json
{
  "schema": 1,
  "unityVersion": "6000.6.6f1",
  "build": {
    "devMethod": "Game.Editor.Build.DevelopmentApk",
    "releaseMethod": "Game.Editor.Build.ReleaseApk",
    "apkPath": "Builds/Android/game.apk"
  }
}
```

| Key | Type / default / purpose |
| --- | --- |
| `schema` | Integer `1`. |
| `unityVersion` | Nonempty string; editor/image/cache version. |
| `build.devMethod` | Fully qualified execute method; required unless `build.profile` is set. |
| `build.releaseMethod` | Release execute method; required unless `build.profile` is set. |
| `build.apkPath` | Required relative development APK output path. |
| `build.releaseApkPath` | Relative release output path; defaults to `build.apkPath`. |
| `build.profile` | Optional relative committed build-profile asset path. Uses Unity CLI `build --profile` instead of execute methods, supporting projects without a custom build API. |
| `build.cli` | Optional executable for profile builds; default `unity`. |
| `knownFlakes` | Optional relative flakes-list path (Quest also accepts an absolute path); omitted or missing file means no flakes. |
| `labMethod` | Optional fully qualified execute method for `lab`. |
| `setup.craneArchive` | Optional download location for a crane archive; unnecessary with preinstalled crane. |
| `scene` | Optional object. Omit entirely for projects without a generated scene. |
| `scene.steps` | Required nonempty ordered array of fully qualified execute methods when `scene` exists. Logs use each method's declaring class. |
| `scene.lightmapDir` | Required relative lightmap directory when `scene` exists; only `Lightmap-*.exr.meta` platform settings are eligible for cleanup. |
| `scene.keepPaths` | Optional array of relative files/directories protected during scene cleanup; default empty. |
| `scene.areaStep` | Optional fully qualified execute method receiving repeated `-area Area` arguments. Requires `scene.areasDir`. |
| `scene.areaSteps` | Optional nonempty array for area-only generation; default first scene step followed by `areaStep`. |
| `scene.areasDir` | Relative directory of area prefabs; selected `Area.prefab` paths are protected. |
| `scene.areasFile` | Optional relative area-to-builder glob table (`Area path-glob...`, comments with `#`); used for informational test selection output. |
| `noise.artRoot` | Optional project-relative directory scanned for scene serialization noise; default `Assets/Art`. Other configured noise paths are still checked independently. |
| `noise.protectedRegex` | Protected-path ERE; default `^Assets/Scenes/`. |
| `noise.sourceRegex` | Prop-source extension ERE; default GLB/FBX/image extensions, including `.meta`. |
| `noise.generatorsRegex` | Generator-source path ERE; disabled if omitted. |
| `noise.codeRegex` | Real regeneration inputs; default scripts/editor paths and `.cs`/`.asmdef`. |
| `noise.atlasPath` | Optional exact shared atlas path; atlas re-encode cleanup disabled if omitted. |
| `noise.timeManagerPath` | Default `ProjectSettings/TimeManager.asset`; only fixed-timestep formatting is eligible. |
| `noise.fixedTimestepCount` | Optional positive decimal string for Unity's rational fixed-timestep representation (ticks at Unity's 141120000 Hz rate). Without it, rational-count cleanup is disabled. |
| `noise.specularMaterialPath` | Optional exact material path eligible for `_SPECULAR_COLOR`-only keyword cleanup; disabled if omitted. |
| `noise.fontAssetPaths` | Optional list of exact repository-relative static font asset paths (default empty). Revert any newly introduced serialization change at these paths, never deletions or `.meta` files; dirty-before/staged and `--keep` protections still apply. Only opt in fonts whose editor changes are disposable. |
| `noise.propsDir` | Prop sources directory; default `Assets/Art/Props`. |
| `noise.repackRegex` | Optional eligible prop mesh/prefab path ERE (capture group 1 labels the prop); disabled if omitted. |
| `tests.root` | Optional relative test discovery root; default `Assets/Tests`. Used for Gfx eligibility, area tags and RenderTool discovery. |
| `tests.editModeRoot` | Optional relative EditMode root for changed tests and scripts-area lookup; default `<tests.root>/EditMode`. Keep it within `tests.root` so Gfx tags can be discovered. |
| `tests.scriptsRoot` | Optional relative runtime code root; default `Assets/Scripts`. Changes under `<scriptsRoot>/<Area>/` search that area's EditMode fixtures. |
| `tests.editorRoot` | Optional relative editor code root; default `Assets/Editor`. Builder changes search all fixtures under `tests.root` for references. |
| `tests.builderFixtures` | Optional object mapping exact builder paths to arrays of fully qualified fixture names. |
| `tests.prPure` | Optional object enabling pure fixture selection for `test pr`; omit to retain full pure. |
| `tests.prPure.smokeFixtures` | Array of fixture class names (namespace-qualified when applicable), default empty. Include only fixtures intended for the headless pure pass. |
| `tests.prPure.max` | Integer cap from 0 through 9999999, default 12. Zero forces the full pass. |
| `tests.prPure.fallbackRegex` | Optional nonempty jq regex matched against project-relative changed paths, in addition to built-in infrastructure checks. |

Configuration paths are normalized once on load: `./`, repeated separators,
and trailing separators do not change keep safeguards or source detection.
Standalone cleanup includes `scene.keepPaths` as well as CLI `--keep` paths.
Paths used as outputs cannot be absolute or contain `..` components. Strings
cannot be empty or contain control characters. Regex values are trusted project
policy: keep them anchored and narrow, especially the repack eligibility rule.
Test/code roots must also be relative strings without `..` components. Omit
all four keys to preserve the conventional layout. For a nested consumer layout:

```json
{
  "tests": {
    "root": "Assets/_Project/Tests",
    "editModeRoot": "Assets/_Project/Tests/EditMode",
    "scriptsRoot": "Assets/_Project/Scripts",
    "editorRoot": "Assets/_Project/Editor",
    "builderFixtures": {}
  }
}
```

The `Gfx`, `MacOnly`, `RenderTool`, and `Area:<name>` NUnit categories remain
shared runner conventions, not generated game content. These roots affect test
selection only; scene cleanup's `noise.codeRegex` policy is unchanged.

## Test without Unity

For ordinary PRs, the broad gate is only `Tools/ship/test-all.sh --changed`
followed by `Tools/vendor/tests/run.sh`. Docs-only PRs use the short lint/format
gate in [AGENTS.md](../../AGENTS.md) instead. While iterating on code, run
focused tests (including relevant slow regressions), for example:

```sh
Tools/ship/tests/run.sh quest-release.test.sh
```

Pass one or more exact test basenames to the runner for the same isolation
and timeout as CI. It defaults to one worker per available CPU, capped at eight
(`SHIP_TEST_JOBS=1` for sequential execution); `# test-all: serial` files run alone after the parallel
batch. Each file has isolated temporary and home directories. Output is grouped
per completed file, including elapsed seconds, total duration and the five slowest
files. Its test-only jq wrapper memoizes the three pure config
filters by filter and input bytes; config changes invalidate entries and other
queries run normally. The release-flow fixture also reuses immutable parsed JSON;
config validation/mutation is exercised separately. Production scripts are unchanged.
Run the full `Tools/ship/tests/run.sh` suite locally only for release PRs
(version bump/tag) or shared test-infrastructure changes (`tests/lib/`,
`tests/run.sh`, fixtures), and only if the changed run did not already cover
all Ship tests. If `--changed` reports `[shell-test] passed N files` and N equals
the number of `Tools/ship/tests/*.test.sh` files, cite that run as the full Ship
receipt; do not rerun `Tools/ship/tests/run.sh`. Otherwise, when the PR requires
the full Ship suite, run:

```sh
Tools/ship/tests/run.sh
```

The [Ship CI workflow](../../.github/workflows/ship.yml) is path-filtered to
Ship and its workflow, and always runs the full suite when triggered.

The local aggregate runner `Tools/ship/test-all.sh` defaults to changed Ship
files since the merge-base with `origin/main`, including staged, unstaged and
untracked changes; unrelated changes select no tests. This is broad quick-test
selection, not a precise dependency graph: a changed `*.test.sh` selects itself;
other Ship paths (including docs, shared tooling and fixtures) or the Ship
workflow select all quick tests. Slow tests tagged
`# test-all: slow [script-basename ...]` require a change to their own file or a
shell/Python script explicitly named in the tag; incidental references do not
opt them in. `--fast` omits all slow-tagged tests. Use
`Tools/ship/test-all.sh --changed <base>` for another comparison base. Positional
basename-substring filters intersect changed selection; use, for example,
`Tools/ship/test-all.sh --all quest-release` to run matching tests regardless of
changes. Unfiltered `--all` runs the full suite, including slow tests.

Part B adds the offline shell tests and CI entry point. No editor, account,
network, activation or seat is needed. Generated-scene and no-scene fixtures
cover both project shapes. Installation, licensing, curl, cache and editor
processes are substituted with local fakes.

## Quest release (macOS)

The [Quest runner](quest-release.sh) consumes the same schema 1 configuration.
Use a licensed Mac with Bash 3.2+, `jq`, Python 3, Git, `adb` on PATH,
and the Unity Hub editor matching `unityVersion` (Android Build Support,
SDK/NDK and OpenJDK installed). Release worktrees need an APFS volume for
`cp -c -R` Library clones and at least 25 GB free. Prepare a clean, warm
worktree at `$HOME/wt/<repo name>/mac-pass` first. The editor version in
`ProjectSettings/ProjectVersion.txt` must agree with configuration.

Without `quest.signing`, use the existing debug keystore at
`$ANDROID_USER_HOME/debug.keystore` (default `$HOME/.android/debug.keystore`),
not a newly generated key. This debug behavior is unchanged. For a release
keystore, opt in with `quest.signing` as described below. Set `QUEST_CERT_SHA256`
to the certificate fingerprint expected by the installed application, obtained
independently with `keytool`. It has **no baked-in value**. Without signing
config, builds drop `XDG_CONFIG_HOME` so the debug path uses that same keystore;
custom-signing builds preserve the inherited environment.
`doctor` checks Java, apksigner, keystore, editor, free disk, adb, idle status
and concurrent runs without creating a release log or worktree, starting Unity
or changing headset app data. If the selected adb transport drops or is offline,
`doctor` tries one serial-scoped reconnect, waits for the device and rechecks
its state and manufacturer, all under one `QR_DEVICE_CHECK_WAIT` deadline.
It never resets other transports or retries an unauthorized or non-Oculus
headset. Set `QUEST_SERIAL` explicitly when the headset is absent from
`adb devices`; `doctor` does not guess which device to wait for. A timeout
fails the device check and skips the idle probe. No real headset or Mac is
needed for the synthetic shell tests.

### Configuration

Add an optional `quest` object to schema 1. Omitting it leaves Linux commands
unchanged; Quest commands require it and `build.devMethod` (profile-only
projects must supply a development execute method for this runner).

```json
{
  "quest": {
    "package": "com.example.game",
    "worktreeRoot": "$HOME/wt/consumer",
    "apkKeepName": "game-dev-{sha}.apk",
    "backupPrefix": "consumer-backup-",
    "perfLogTag": "[GamePerf]",
    "launchLogTags": [
      "Unity",
      "Synthetic.Tag"
    ],
    "launcherChecks": {
      "package": "com.example.game",
      "permissions": [
        "android.permission.RECORD_AUDIO"
      ],
      "assets": [
        "assets/synthetic-content.bin",
        {
          "glob": "assets/bundles/*.bundle"
        }
      ]
    },
    "whatsNewEnv": "YETIKIT_WHATS_NEW",
    "prevShaEnv": "YETIKIT_PREV_SHA",
    "dataFiles": [
      "playtest.json",
      "throws.csv"
    ],
    "launchArgs": []
  }
}
```

| Quest key | Type / default / purpose |
| --- | --- |
| `package` | Required dotted Android application ID. Used for launcher verification, data storage and process/crash attribution. |
| `worktreeRoot` | Nonempty path; default `$HOME/wt/<repo name>`. Relative paths resolve against the project; leading `~/` and `$HOME/` expand without shell evaluation. |
| `apkKeepName` | Filename pattern containing `{sha}`, default `game-dev-{sha}.apk`. Only letters, digits, `.`, `_`, `-` and braces; no directories. Substitutes the nine-character commit prefix. |
| `backupPrefix` | Backup folder name prefix, default `Quest-playtest-backup-`. Use letters, digits or `_` first; remaining characters may also include `.` and `-`. The timestamp is appended directly, followed by a device suffix for multi-headset runs. The parent directory is still selected by `QUEST_BACKUP_ROOT`. |
| `perfLogTag` | Optional literal log tag preceding `fps=…`; omitted means no FPS extraction. |
| `launcherChecks` | Optional object; Unity GameActivity/VR launcher/theme and ZIP checks always apply. |
| `launcherChecks.package` | Optional expected package, must equal `quest.package`. |
| `launcherChecks.permissions` | Optional array of full permission names required in the APK. After install or rollback, the report shows only these permissions' grant states. An omitted or empty list skips the device permission query. |
| `launcherChecks.assets` | Optional array of exact APK entry strings or `{"glob": "pattern"}` objects; default empty. Each requirement must match. No absolute paths or parent traversal. |
| `launchLogTags` | Optional array of nonempty, literal logcat tags. Omitted or empty means no counts are printed. |
| `whatsNewEnv` | Build notes environment-variable name; default `YETIKIT_WHATS_NEW`. `--notes` exports the absolute notes filename. |
| `prevShaEnv` | Previous-installed-commit environment-variable name; default `YETIKIT_PREV_SHA`. Build receives the latest successful install's commit unless already supplied. |
| `dataFiles` | Optional array of safe basenames to back up and hash-check; default `playtest.json`, `throws.csv`. `SHA256SUMS` is reserved for backup metadata. Empty means no application-specific files. Contents never print. |
| `launchArgs` | Optional string array appended to `adb shell am start`; default empty. No game-specific launch extras are built in. |
| `signing` | Optional object selecting a release keystore for certificate lookup. Omit to retain identical debug-keystore behavior. |
| `signing.keystorePathEnv` | Required when `signing` is present: name of the environment variable containing the keystore path. |
| `signing.storePassEnv` | Required when `signing` is present: name of the environment variable containing the keystore password. |
| `signing.keyAliasEnv` | Required when `signing` is present: name of the environment variable containing the key alias. |
| `signing.keyPassEnv` | Optional name of the environment variable containing the key password. Not used for certificate lookup; remains inherited by the consumer build. |

Asset globs are matched case-sensitively against full APK file entry names, not
against files on disk. Shell-style `*`, `?` and bracket classes are supported;
`*` can span `/`. Strings are always exact paths, even if they contain wildcard
characters. APK checks fail with the pattern if a glob has no match. In
`--contest` mode, any match for a configured glob is forbidden instead.

After the launch wait, the runner prints one count (including zero) per
configured `launchLogTags` entry and saves the counts in `launch-report.txt`.
Counts use the exact tag field, not message text, in the final device-wide
logcat snapshot, not the overlapping early snapshot. They do not affect the
launch verdict.

`quest.serial` is rejected: the headset serial belongs **only** in environment
variable `QUEST_SERIAL`. For `install`, `launch`, `rollback` and `all`, it accepts
an ordered comma- or whitespace-separated list, for example
`QUEST_SERIAL='synthetic-A,synthetic-B' Tools/yetikit/quest-release.sh all`.
A single serial keeps the existing behavior and artifact paths. If unset, the
runner requires exactly one attached adb
device; zero or multiple devices fail clearly instead of choosing one. Never
commit device identity, signing fingerprints or private provenance to config.

List release artifacts go under `devices/<encoded-serial>/`. Lowercase ASCII
letters, digits, hyphens and underscores stay literal; other bytes (including
uppercase letters) use `%HH` escapes so case-only serials have separate paths.
In a reused run, the summary keeps the latest list rows for each step. Its
`overall` verdict and exit code describe only the current command.

### Optional release signing

Add `signing` inside the existing `quest` object to map environment-variable
names, **not** paths, aliases or passwords:

```json
{
  "signing": {
    "keystorePathEnv": "CONSUMER_KEYSTORE_PATH",
    "storePassEnv": "CONSUMER_STORE_PASS",
    "keyAliasEnv": "CONSUMER_KEY_ALIAS",
    "keyPassEnv": "CONSUMER_KEY_PASS"
  }
}
```

Use dedicated signing variables: every mapped name must match
`[A-Z][A-Z0-9_]*` and must not start with `QR_` (reserved for the runner).
Lowercase names such as `name`, `ks` and `got` can collide with Bash locals,
and leading underscores are not supported. Rename any such variable in both
the launcher environment and the signing config. There are no fallback signing
environment variables: when `signing` is present, supply the variables
named by its three required fields. Omit `keyPassEnv` if the consumer build does
not need a separate key password. The runner does not use it for certificate
lookup, but build preflight and doctor require every named variable (including
`keyPassEnv`, if configured) to be exported and nonempty. A missing custom
keystore is a failure, naming `keystorePathEnv`'s variable rather than its value.
In contrast, a missing debug keystore only warns because Gradle can create it.

For example, in a private shell with tracing disabled, load passwords from your
secret manager into the mapped variables, then inspect the release certificate:

```sh
export CONSUMER_KEYSTORE_PATH="/path/to/private/release.keystore"
export CONSUMER_KEY_ALIAS="release"
# Load and export CONSUMER_STORE_PASS securely; do not put its value here.
# Also load and export CONSUMER_KEY_PASS if the consumer build needs it.
keytool -list -v -keystore "$CONSUMER_KEYSTORE_PATH" -storepass:env CONSUMER_STORE_PASS -alias "$CONSUMER_KEY_ALIAS"
# Set this to the release certificate's SHA-256 fingerprint from that output.
export QUEST_CERT_SHA256="<release-certificate-sha256>"
Tools/yetikit/quest-release.sh doctor
```

Certificate lookup passes the password with `keytool -storepass:env`, never as
an inline password argument. PKCS12 and JKS keystores are autodetected; no store
type setting is needed. Keep the keystore, passwords and fingerprint out of
committed configuration. Confirm the release certificate matches the installed
application before proceeding; changing certificates cannot update that app in
place.

The consumer's `build.devMethod` performs the actual APK signing, using the
inherited environment. The runner's `quest.signing` mapping only selects the
certificate to check; it does not configure Unity signing or re-sign the APK.
Prebuilt `verify`, `install` and `rollback` require `QUEST_CERT_SHA256` but do
not require the keystore or signing credentials: they check the APK's signer
directly.

### Commands

```sh
Tools/yetikit/quest-release.sh doctor
Tools/yetikit/quest-release.sh all
Tools/yetikit/quest-release.sh all origin/main --full --notes /tmp/release-notes.txt --rollback /tmp/previous.apk
Tools/yetikit/quest-release.sh prepare origin/main
Tools/yetikit/quest-release.sh gate
Tools/yetikit/quest-release.sh build
Tools/yetikit/quest-release.sh verify /tmp/game.apk
Tools/yetikit/quest-release.sh install /tmp/game.apk
Tools/yetikit/quest-release.sh launch
Tools/yetikit/quest-release.sh rollback /tmp/previous.apk
Tools/yetikit/quest-release.sh cleanup
Tools/yetikit/quest-release.sh cleanup --discard-noise
Tools/yetikit/quest-release.sh summary
Tools/yetikit/quest-release.sh wait 28
```

`cleanup` removes only clean worktrees, without forcing Git removal. Any local
change (even a material/settings re-save) is preserved for manual inspection;
file extensions alone never prove disposable noise. Opt into `cleanup
--discard-noise` to discard changes in a release worktree only when every
change is an unstaged file edit recognized by Ship's editor-run noise rules
(the same rules used after `open` and `test`, including configured noise paths).
For prefabs, only spelling changes in recognized transform vectors that keep
the same serialized float value count as noise.
A worktree with staged or untracked work, deletions, or unclassified edits is
kept intact with a reason. This flag is only for standalone `cleanup`; `all`
continues to remove only clean worktrees.

`prepare` (also used by `all`) fetches origin without prompting. Quest release
retries Git `fetch`, `pull` and `ls-remote` on recognized transient transport
errors (for example, connection timeouts or HTTP 503). It makes at most three
attempts, waiting one second before the second and two before the third. This
caps attempts, not the duration of an individual Git command. Authentication,
missing refs and local Git errors are not retried. Exhausted retries report
failure and stop `prepare` before worktree creation.

`all` fetches origin and resolves a commit, creates separate detached test/build
worktrees with independent cloned Libraries, runs gate/build in parallel, then
verifies, installs, launches and cleans up. A failed gate never installs; the
built APK and failed worktrees remain for inspection. `--rollback` reinstalls the
previous APK only after a confirmed launch crash, never an adb, logcat or device
failure. Rollback still checks whether the headset is idle; only the user's own
`all --force` bypasses a known busy headset. Infrastructure failures leave the
installed build in place and return non-zero. Standalone steps use the current run's
state under `release-logs/current.env`. `summary` reprints the latest step results.

With several serials, gate/build/sign/primary APK verification run once, followed
by each device's check, idle check, backup, install, launch and optional rollback
before moving to the next device. Standalone install/rollback also verify their
APK once. Devices run in the supplied order; failures do not stop later devices.
A busy or unverified headset blocks only its own install (and therefore its
subsequent launch in `all`). Standalone `launch` retains the existing behavior:
connectivity/manufacturer checks, but no install idle check. Rollback targets
only the device whose launch confirmed a crash, and still respects its idle check
unless `all --force` was supplied. A rollback APK is verified once separately
before any device operations. List installs verify and install private, temporary
copies: replacing the source APK during the run cannot change what later devices
receive.

Multi-device artifacts live inside the run folder at `devices/<encoded-serial>/`:
`install-adb.log`, `rollback-adb.log` when used, `launch-logcat.txt`,
`launch-report.txt`, the other launch diagnostics, and a device-local `summary/`.
Folder names preserve ASCII letters, digits, `_` and `-`; every other byte is
percent-encoded (including `%`), so `192.168.0.5:5555` becomes
`192%2E168%2E0%2E5%3A5555`. Top-level `summary.txt` and `wait` show
`install[<serial>]`, `launch[<serial>]`, and any `rollback[<serial>]` lines with
`OK`, `CRASH` or `INFRA`, plus the overall outcome. Original serials appear only
in the report, not as raw paths. Single-device logs stay at the run root.

`gate` runs Metal EditMode `Gfx;MacOnly` tests (`--full` runs all). All failures
listed in `knownFlakes`, or exactly one failure whether listed or not, rerun
once with the same categories and exact selected filter. Retry coverage and
result counts must prove the selected tests actually passed. Missing results,
crashes and empty runs fail closed. The summary labels a passing retry.
The flakes list is read from the test worktree first, falling back to the main
checkout if absent. Absolute config paths and absolute `QUEST_KNOWN_FLAKES`
overrides are used as-is.
`build` uses `build.devMethod` and `build.apkPath`; a log-growth stall kills only
that editor, retries once, then fails. The retained APK has commit provenance.
Notes are supplied through the configured variable names; interpreting those
variables and numbering the build remains the consumer's build method's job.

`verify` invokes [the launcher checker](android-launcher.py), then apksigner
and SHA-256. The checker also accepts `--config <yetikit.json>` with a source
manifest or built APK. Its compatibility `--contest` mode instead requires the
configured development permissions/assets to be absent; the Unity contract is
still mandatory. `launch` captures logcat at 30 seconds (when the configured
wait exceeds 30), then at the final deadline; it reports optional FPS, errors,
package-attributed crashes, alive status and Quest-shell launch warnings. Shell
warnings alone do not trigger rollback and a live process is not proof of XR
presentation. `launch` exits **0** for a healthy observed process, **1** for a
confirmed crash (`CRASH:`: package-attributed crash/ANR evidence or a process
observed after start that is gone at the final probe), and **3** for an
infrastructure/unverified result (`INFRA:`). An OS/launcher blocked-launch record
naming the exact package reports `INFRA: launch blocked by the OS: <reason>`
with the hint `clear the dialog on the headset and rerun`. A process absent at
both PID probes without attributed crash evidence reports
`INFRA: process never started (no crash evidence)`. Neither case rolls back.
Device checks, activity start, logcat capture (including the early snapshot),
and failed/malformed pidof probes are infrastructure errors.
The probe checks adb's transport status separately from the remote pidof status;
remote exit 1 with no output confirms absence, not a transport failure.
Multi-device exit status uses **crash (1) > infrastructure (3) > OK (0)**,
regardless of device order. Install refusals, lock failures and busy/unknown idle
checks are infrastructure failures (3) in list runs; only confirmed launch
crashes count as crash (1), even after a successful rollback. Every selected
device must succeed for exit 0. Single-device exit codes are unchanged.
`summary.txt` and `wait` retain the `CRASH:`/`INFRA:` distinction; `wait` returns
1 for either failure. Logs and summaries remain in `<worktreeRoot>/release-logs/`.

For detached operations, use `nohup … all > /tmp/quest-release.out 2>&1 &`, then
`wait 28` within the caller's command timeout. `wait` takes no lock and writes
nothing: exit 0 means the watched invocation succeeded and installed (or a
standalone gate passed), 1 means failure/missing terminal result, and 124 means
the bounded wait expired. It prints progress once a minute. Mutating commands
publish their invocation identity before device discovery; `wait` requires that
invocation's terminal result even when discovery fails before preparing a new
run folder, rather than accepting an earlier release's successful summary. For
list releases, that result includes the aggregate verdict and report, even if
a successor has already started changing the shared summary in the same folder.

## Quest performance capture

`Tools/ship/quest-release.sh perf [--seconds N] [--warmup S]` launches the
installed app using the same activity/argument path as `launch` (including
`quest.launchArgs`). It disables the proximity sensor, polls every 0.2 seconds
for one live app PID (up to `QR_PERF_PID_WAIT`, default 20 seconds), then starts
warm-up, clears logcat, captures the window and restores the sensor. The capture
runs `adb logcat -c` after warm-up: earlier logcat is lost, so save it first if
you need it. Multiple
PIDs or no PID by the deadline is INFRA. Cleanup traps restore the sensor on
failures and cancellation too. Each restoration attempt is bounded by
`QR_PERF_RESTORE_WAIT` (default 10 seconds); failed/timed-out restoration logs a
WARN with a manual adb recovery command in the per-device summary. Failed
restorations remain pending per device in the run folder. Cancellation retries
pending restorations under the corresponding headset locks, publishes a fresh
cancellation result and releases run ownership. An unreachable device is an
infrastructure failure, not success. No build, install, editor or credentials
are needed.

### Record a live session

1. Launch the configured app and navigate to the workload before recording.
2. Run `Tools/ship/quest-release.sh perf start`. Wait for it to succeed before
   measuring. It records each selected headset's device-clock start and app
   PID and holds its proximity override open. It does not launch the app,
   clear logcat, or apply warm-up.
3. Run `Tools/ship/quest-release.sh perf stop` while the same app is still in
   the foreground. Use the same checkout, log root, and device serial(s).
   Stop sets a separate end for each headset, restores proximity, and writes
   the same text and JSON summaries as scripted perf. Duration is measured,
   not configured; neither manual command accepts `--seconds` or `--warmup`.
   Scene is `unavailable` because the tool did not choose it.

A manual window belongs to one serial, so you can stop a subset of a list. A
second start cannot replace an open window, and stop without a matching start
is INFRA. The host-local reservation blocks other release commands that mutate
that headset, even from another checkout. Direct adb or a different host is not
covered by this lock. Do not restart or background the app during a window:
manual capture checks identity at both ends, not continuously. Only records
from the persisted start (inclusive) to stop (exclusive) enter the manual
logcat artifact and summary. Long windows can lose samples as logcat rolls
over; missing coverage is INFRA.

After an interrupted start/stop or failed restoration, reconnect the headset
and retry `perf stop` from the owning checkout and log root. If a usable window
was not recorded or was already consumed, the retry restores proximity but
reports INFRA instead of issuing a capture result. Use the same host and user
throughout, and always stop open windows when finished.

Optional configuration under `quest`:

```json
{
  "perf": {
    "warmupSeconds": 10,
    "seconds": 60,
    "maxStalePercent": 1,
    "maxP95AppMs": 13.9,
    "devices": {
      "Quest 2": "gate",
      "Quest 3": "report"
    }
  }
}
```

All shown numeric values are defaults. Warm-up is a nonnegative integer,
capture seconds a positive integer, thresholds nonnegative numbers. `devices`
is an optional model-to-`gate`/`report` map, keyed by `ro.product.model`;
unlisted models **report only**. CLI durations override configuration.

The compositor's once-per-second `VrApi` records are parsed by field name,
tolerating reordered/optional fields. Stale percent is `100 * sum(Stale) /
sum(FPS frames)`. App p95 uses nearest-rank **per-second samples**, not individual
frame telemetry. Both thresholds are inclusive. Average FPS never gates.
Missing gate inputs in any sample make that gate unavailable (FAIL in gate
mode); missing optional measurements say `unavailable`. No samples is INFRA,
never PASS. Captures also require the same unique app PID and resumed package
through warm-up and each second of the scripted window, or at both edges of a
manual window. PID-filtered epoch logcat is
validated again while parsing, so another process cannot supply passing samples.
Missing/replaced/backgrounded app identity is INFRA. Capture uses a fractional
device epoch and a monotonic host deadline; a device-clock query taking 500 ms
or longer invalidates the capture. Coverage requires at least N−1 samples
(minimum one), a timestamp span of at least N−2 seconds, and no nonpositive or
greater-than-1.5-second intervals. This allows boundary jitter, not a missing
interior record; insufficient coverage is INFRA in both modes.
CPU and GPU frame-time means are reported separately when present.
The stale streak counts adjacent samples with Stale > 0, resetting on an epoch
timestamp gap greater than 1.5 seconds. No interpolation fills lost samples.

Each selected `QUEST_SERIAL` receives `perf-summary.txt`, `perf-summary.json`
and `perf-logcat.txt` in the current run directory (encoded `devices/`
subfolders for lists, same as install/launch). The installed APK SHA-256 is
included alongside installed versionName/versionCode; absent metadata is
unavailable. Thermal readings use first/last sample `Temp`, falling back to
`dumpsys thermalservice` status at the capture boundaries, or unavailable. Example synthetic gate-mode summary excerpt:

```text
Quest performance: PASS
device model: Quest 2 (gate)
CPU/GPU levels: 4/4
thermal start/end: 33.0C/0.0C / 34.0C/0.0C
APK versionName/versionCode: 1.2 / 12
scene: benchmark
window: 60s; warm-up excluded: 10s; samples: 60
stale frames: 0% <= 1%: PASS
App p95 (per-second samples): 12 ms <= 13.9 ms: PASS
average fps (report only): 72
worst App: 13 ms
longest consecutive stale seconds: 0
```

Overall is PASS/FAIL in gate mode, REPORT in report-only mode, or INFRA on
capture failure. Exit codes: **0** PASS/REPORT, **1** gate failure, **3**
infrastructure failure (including adb errors/no data). Lists continue after
failures and reduce with the existing launch precedence **1 > 3 > 0**.
`summary.txt` and `wait` include each device's performance summary; `wait`
retains its existing 0-success / 1-failure contract.

### Safety

- Never uninstall, clear app data, grant or revoke permissions. Installation
  uses **`adb install -r` only**; explicit rollback also adds `-d`.
- Verify the APK launcher and matching signer before installation, including
  standalone install and rollback. A mismatched or missing signer fails closed.
- Require an Oculus device and check focused activity plus current headset-worn
  state immediately before install. Unknown idle state refuses even with
  `--force`; that flag bypasses only a known in-use verdict.
- Back up configured data files with device/local hash equality before install,
  then check that data did not change. Never print file contents.
- Serialize each log root with an atomic PID-aware run lock. Device operations
  additionally use a shared per-headset lock across projects/log roots under
  `/tmp/yetikit-quest-device-locks-$UID` (hashed runtime serial). Stale
  locks are taken one at a time in input order and held across that device's
  install/launch/optional rollback; no run holds two headset locks. Stale
  locks are reclaimed only after their owners and workers are gone; cancellation
  drains the owned process group before releasing its lock.
- Device reconnect, Unity work, stall recovery and `wait` all have bounded waits.
  No default identity, private endpoint or signing certificate is embedded.

### Environment

| Variable | Default / purpose |
| --- | --- |
| `PROJECT`, `YETIKIT_CONFIG` | Consumer root / root `yetikit.json`; `QUEST_REPO` remains a compatibility root override. |
| `QUEST_SERIAL` | Environment-only serial or ordered comma/whitespace list for all/install/launch/rollback/perf; otherwise require exactly one attached device. |
| `QUEST_CERT_SHA256` | Required expected APK signer for doctor/build/verify/install/rollback; use the release certificate with `quest.signing`. No default. |
| `QUEST_WT_ROOT`, `QUEST_WARM_WORKTREE` | Configured worktree root / `<root>/mac-pass`. |
| `QUEST_LOG_ROOT`, `QUEST_APK_DIR` | `<root>/release-logs` / warm worktree plus directory of `build.apkPath`. |
| `QUEST_BACKUP_ROOT` | `$HOME`; backups contain private application data, keep them private. |
| `QUEST_MIN_FREE_GB` | `25`. |
| `QR_GATE_TIMEOUT`, `QR_BUILD_TIMEOUT` | `1800` seconds each. Compatibility aliases: `QUEST_GATE_TIMEOUT`, `QUEST_BUILD_TIMEOUT`. |
| `QR_BUILD_STALL_SECONDS` | `300` seconds without log growth; one retry. |
| `QR_ADB_WAIT`, `QR_LAUNCH_WAIT` | `120` / `60` seconds. Compatibility aliases: `QUEST_ADB_WAIT`, `QUEST_LAUNCH_WAIT`. |
| `QR_DEVICE_CHECK_WAIT` | `10` seconds (positive integer) for doctor's selected-device probe, reconnect/wait and recheck combined. |
| `QR_PERF_PID_WAIT`, `QR_PERF_RESTORE_WAIT` | `20` / `10` seconds (positive integers): initial perf PID discovery / each proximity restoration attempt. |
| `QUEST_GATE_CATEGORIES` | `Gfx;MacOnly`; `--full` removes the category filter. |
| `QUEST_KNOWN_FLAKES` | Configured `knownFlakes`, otherwise no list. |
| `QUEST_WAIT_POLL` | `5` seconds between read-only `wait` checks. |
| `UNITY_HUB_EDITORS`, `UNITY_BIN` | `/Applications/Unity/Hub/Editor` / explicit editor executable. |
| `JAVA_HOME`, `ANDROID_SDK_ROOT`, `AAPT` | Explicit tools, otherwise matching editor's Android support SDK/OpenJDK and newest build-tools. |
| `ANDROID_USER_HOME` | `$HOME/.android`; contains `debug.keystore`, used when `quest.signing` is absent. |
| configured signing names | Keystore path, store password and key alias for certificate lookup; optional key password is inherited by the consumer build, not used for lookup. No fallback names. |
| configured notes / previous-SHA names | `YETIKIT_WHATS_NEW` / `YETIKIT_PREV_SHA`; environment only. |
