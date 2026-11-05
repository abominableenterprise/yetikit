# Ship: headless Unity on Linux

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
x86-64 executable. No download service address is embedded in Ship.

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
| `lab` | Run the optional `labMethod`. |
| `apk [dev\|release\|contest]` | Android build on Xvfb; `contest` is a compatibility alias for `release`. Print path, size and SHA-256; remove stale APK before building. |
| `cache-key [android]` | Bare SHA-256 of package manifest, lockfile, project editor version and configured Unity version; Android has its own key. |
| `cache-restore` / `cache-save` | Use external `task-cache` when available; missing service is a no-op, failed/timed-out restore falls back to cold import. |
| `stop` | Stop only this runner's recorded process tree/marked descendants, never a broad process-name kill. |
| `all` | Setup, activate, open, EditMode tests; retain the licence even on failure. Return once afterward. |

For an explicit category, EditMode runs a single graphics-enabled pass; Gfx
gets its own timeout. A RenderTool class filter runs alone with `RenderTool`.
Known flakes are one fully qualified test or fixture per line, with `#` comments.
Only a pass consisting entirely of known failures reruns once. Both result XMLs
are retained and a successful retry prints `flaky-passed`, not an unqualified
first-pass success. Missing results/crashes are never flakes.

`open`/`test` revert only newly introduced material float/keyword or prefab float
formatting noise; `scene` also handles configured atlas repacks and bake-only
lightmap `platformSettings`. Dirty-before/staged files and `--keep` paths survive.
A bare `--keep` on open/test skips cleanup. Exit **3** means editor/test work
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
| `knownFlakes` | Optional relative flakes-list path; omitted or missing file means no flakes. |
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
| `noise.propsDir` | Prop sources directory; default `Assets/Art/Props`. |
| `noise.repackRegex` | Optional eligible prop mesh/prefab path ERE (capture group 1 labels the prop); disabled if omitted. |
| `tests.builderFixtures` | Optional object mapping exact builder paths to arrays of fully qualified fixture names. |

Configuration paths are normalized once on load: `./`, repeated separators,
and trailing separators do not change keep safeguards or source detection.
Standalone cleanup includes `scene.keepPaths` as well as CLI `--keep` paths.
Paths used as outputs cannot be absolute or contain `..` components. Strings
cannot be empty or contain control characters. Regex values are trusted project
policy: keep them anchored and narrow, especially the repack eligibility rule.
The conventional `Assets/Scripts`, `Assets/Editor`, and `Assets/Tests/EditMode`
layout and the `Gfx`, `MacOnly`, `RenderTool`, and `Area:<name>` NUnit categories
are shared runner conventions, not generated game content.

## Test without Unity

```sh
Tools/ship/tests/run.sh
```

Part B adds the offline shell tests and CI entry point. No editor, account,
network, activation or seat is needed. Generated-scene and no-scene fixtures
cover both project shapes. Installation, licensing, curl, cache and editor
processes are substituted with local fakes.
