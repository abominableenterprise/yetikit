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

## Commands

| Command | Behaviour |
| --- | --- |
| `setup [--android] [--no-creds]` | Stream the versioned GameCI base/android image into `UNITY_ROOT` (default `/opt/unity`), install libraries and the `merge.ours` Git driver. `--no-creds` provisions without activation. An Android setup replaces a complete base-only install. |
| `activate` / `return` | Activate/reuse a Personal ULF licence; return once and release the seat. |
| `open [--keep [path]]...` | Compile/open without graphics. A cold project restores/saves the Library cache. |
| `test editmode [Unity args...]` | Pure pass (`!Gfx;!MacOnly`) without graphics, then Gfx on Xvfb. `EDITMODE_GFX=0` skips Gfx. |
| `test playmode [Unity args...]` | PlayMode tests on Xvfb. |
| `test pr [base] [Unity args...]` | Full pure pass, then only touched Gfx fixtures (default base `origin/main`). Changed runtime types search their area's tests; editor builders search all tests. No caller `-testFilter`/`-testCategory`. |
| `scene [--keep path]... [--area Area]...` | Run configured generated-scene steps; optionally only configured area steps, then conservative noise cleanup. Without `scene`, explain that no generated scene is configured. |
| `lab [--keep [path]]...` | Run the optional `labMethod`; cleanup/`--keep` as in `open`. |
| `apk [dev\|release\|contest]` | Android build on Xvfb; `contest` is a compatibility alias for `release`. Print path, size and SHA-256; remove stale APK before building. |
| `cache-key [android]` | Bare SHA-256 of package manifest, lockfile, project editor version and configured Unity version; Android has its own key. |
| `cache-restore` / `cache-save` | Use external `task-cache` when available; missing service is a no-op, failed/timed-out restore falls back to cold import. |
| `stop` | Stop only this runner's recorded process tree/marked descendants, never a broad process-name kill. |
| `all` | Setup, activate, open, EditMode tests; retain the licence even on failure. Return once afterward. |

### Test evidence

Test commands reject forwarded `-quit`, `-testResults` and `-logFile` before
starting an editor: the runner owns test execution, result paths and log paths.
Each pass, including a known-flake retry, must write parseable result XML with
a `test-run` root and numeric `total`, `passed`, `failed` and `skipped` counts.
Missing/empty/invalid XML, zero total, or no passed/failed tests fails the pass.
The only zero-total exception is the implicit Gfx pass of plain `test editmode`
(no caller `-testCategory` or `-testFilter`) and the Gfx pass of `test pr`:
projects may have no selected Gfx tests. These log `no tests selected (Gfx
categories); treated as empty`. This never excuses missing/invalid XML, all
skipped tests, or an empty retry. Pure, PlayMode and explicitly selected passes
must execute tests. A later evidence-only failure preserves an earlier editor's
nonzero exit status. Evidence validation uses Python 3's standard library.

For an explicit category, EditMode runs a single graphics-enabled pass; Gfx
gets its own timeout. A RenderTool class filter runs alone with `RenderTool`.
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

Long runs should be backgrounded and observed with the environment's `wait-log`
helper (not bundled here):

```sh
mkdir -p build
Tools/yetikit/linux-unity.sh test pr > build/test-pr.log 2>&1 &
wait-log --pid $! 25
```

Logs/results live in `build/` (`OUT_DIR` override), including `test-stages.log`.
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

```sh
Tools/ship/tests/run.sh
```

The [Ship CI workflow](../../.github/workflows/ship.yml) is path-filtered to
Ship and its workflow. The local aggregate runner defaults to changed Ship
files since `origin/main`, including working-tree changes; unrelated changes
select no tests. Shared tooling, fixtures, or workflow changes select all quick
tests. Slow tests tagged `# test-all: slow [script-basename ...]` require a change
to their own file or a script explicitly named in the tag; incidental references
do not opt them in. `--fast` omits all slow-tagged tests. Use
`Tools/ship/test-all.sh --changed <base>` for another comparison base, or
`Tools/ship/test-all.sh --all` to explicitly run unchanged tests, including slow
ones. The serial command above always runs the full suite for repeatability checks.

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

Use the existing debug keystore at `$ANDROID_USER_HOME/debug.keystore`
(default `$HOME/.android/debug.keystore`), not a newly generated key. Set
`QUEST_CERT_SHA256` to the certificate fingerprint expected by the installed
application, obtained independently with `keytool`. It has **no baked-in
value**. Builds drop `XDG_CONFIG_HOME` so Gradle uses that same keystore.
`doctor` checks Java, apksigner, keystore, editor, free disk, adb, idle status
and concurrent runs, without creating logs, starting Unity or changing a device.
No real headset or Mac is needed for the synthetic shell tests.

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
    "perfLogTag": "[GamePerf]",
    "launcherChecks": {
      "package": "com.example.game",
      "permissions": [
        "android.permission.RECORD_AUDIO"
      ],
      "assets": [
        "assets/synthetic-content.bin"
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
| `perfLogTag` | Optional literal log tag preceding `fps=…`; omitted means no FPS extraction. |
| `launcherChecks` | Optional object; Unity GameActivity/VR launcher/theme and ZIP checks always apply. |
| `launcherChecks.package` | Optional expected package, must equal `quest.package`. |
| `launcherChecks.permissions` | Optional array of required permission names; default empty. |
| `launcherChecks.assets` | Optional array of exact required APK archive paths; default empty. No absolute paths or parent traversal. |
| `whatsNewEnv` | Build notes environment-variable name; default `YETIKIT_WHATS_NEW`. `--notes` exports the absolute notes filename. |
| `prevShaEnv` | Previous-installed-commit environment-variable name; default `YETIKIT_PREV_SHA`. Build receives the latest successful install's commit unless already supplied. |
| `dataFiles` | Optional array of safe basenames to back up and hash-check; default `playtest.json`, `throws.csv`. `SHA256SUMS` is reserved for backup metadata. Empty means no application-specific files. Contents never print. |
| `launchArgs` | Optional string array appended to `adb shell am start`; default empty. No game-specific launch extras are built in. |

`quest.serial` is rejected: the headset serial belongs **only** in environment
variable `QUEST_SERIAL`. If unset, the runner requires exactly one attached adb
device; zero or multiple devices fail clearly instead of choosing one. Never
commit device identity, signing fingerprints or private provenance to config.

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
Tools/yetikit/quest-release.sh summary
Tools/yetikit/quest-release.sh wait 28
```

`cleanup` removes only clean worktrees, without forcing Git removal. Any local
change (even a material/settings re-save) is preserved for manual inspection;
file extensions alone never prove disposable noise.

`all` fetches origin and resolves a commit, creates separate detached test/build
worktrees with independent cloned Libraries, runs gate/build in parallel, then
verifies, installs, launches and cleans up. A failed gate never installs; the
built APK and failed worktrees remain for inspection. `--rollback` reinstalls the
previous APK only after a confirmed launch crash, never an adb, logcat or device
failure. Rollback still checks whether the headset is idle; only the user's own
`all --force` bypasses a known busy headset. Infrastructure failures leave the
installed build in place and return non-zero. Standalone steps use the current run's
state under `release-logs/current.env`. `summary` reprints the latest step results.

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
confirmed crash (`CRASH:`: package-attributed crash lines or a successful probe
confirming the process is gone), and **3** for an infrastructure/unverified
result (`INFRA:`). Device checks, activity start, logcat capture (including the
early snapshot), and failed/malformed pidof probes are infrastructure errors.
The probe checks adb's transport status separately from the remote pidof status;
remote exit 1 with no output confirms absence, not a transport failure.
`summary.txt` and `wait` retain the `CRASH:`/`INFRA:` distinction; `wait` returns
1 for either failure. Logs and summaries remain in `<worktreeRoot>/release-logs/`.

For detached operations, use `nohup … all > /tmp/quest-release.out 2>&1 &`, then
`wait 28` within the caller's command timeout. `wait` takes no lock and writes
nothing: exit 0 means the watched invocation succeeded and installed (or a
standalone gate passed), 1 means failure/missing terminal result, and 124 means
the bounded wait expired. It prints progress once a minute. Mutating commands
publish their invocation identity before device discovery; `wait` requires that
invocation's terminal result even when discovery fails before preparing a new
run folder, rather than accepting an earlier release's successful summary.

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
  locks are reclaimed only after their owners and workers are gone; cancellation
  drains the owned process group before releasing its lock.
- Device reconnect, Unity work, stall recovery and `wait` all have bounded waits.
  No default identity, private endpoint or signing certificate is embedded.

### Environment

| Variable | Default / purpose |
| --- | --- |
| `PROJECT`, `YETIKIT_CONFIG` | Consumer root / root `yetikit.json`; `QUEST_REPO` remains a compatibility root override. |
| `QUEST_SERIAL` | Environment only; otherwise require exactly one attached device. |
| `QUEST_CERT_SHA256` | Required expected APK signer for build/verify/install; no default. |
| `QUEST_WT_ROOT`, `QUEST_WARM_WORKTREE` | Configured worktree root / `<root>/mac-pass`. |
| `QUEST_LOG_ROOT`, `QUEST_APK_DIR` | `<root>/release-logs` / warm worktree plus directory of `build.apkPath`. |
| `QUEST_BACKUP_ROOT` | `$HOME`; backups contain private application data, keep them private. |
| `QUEST_MIN_FREE_GB` | `25`. |
| `QR_GATE_TIMEOUT`, `QR_BUILD_TIMEOUT` | `1800` seconds each. Compatibility aliases: `QUEST_GATE_TIMEOUT`, `QUEST_BUILD_TIMEOUT`. |
| `QR_BUILD_STALL_SECONDS` | `300` seconds without log growth; one retry. |
| `QR_ADB_WAIT`, `QR_LAUNCH_WAIT` | `120` / `60` seconds. Compatibility aliases: `QUEST_ADB_WAIT`, `QUEST_LAUNCH_WAIT`. |
| `QUEST_GATE_CATEGORIES` | `Gfx;MacOnly`; `--full` removes the category filter. |
| `QUEST_KNOWN_FLAKES` | Configured `knownFlakes`, otherwise no list. |
| `QUEST_WAIT_POLL` | `5` seconds between read-only `wait` checks. |
| `UNITY_HUB_EDITORS`, `UNITY_BIN` | `/Applications/Unity/Hub/Editor` / explicit editor executable. |
| `JAVA_HOME`, `ANDROID_SDK_ROOT`, `AAPT` | Explicit tools, otherwise matching editor's Android support SDK/OpenJDK and newest build-tools. |
| `ANDROID_USER_HOME` | `$HOME/.android`; contains `debug.keystore`. |
| configured notes / previous-SHA names | `YETIKIT_WHATS_NEW` / `YETIKIT_PREV_SHA`; environment only. |
