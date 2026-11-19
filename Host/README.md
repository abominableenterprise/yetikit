# Unity test Host

Minimal Unity **6000.6.6f1** project for compiling and testing local kit packages.
Core, hands, interaction and quality are referenced, with `testables` enabled.
The Host includes XR package dependencies for hands, but no scenes or render pipeline. Unity generates
metadata and project defaults on import; commit required metadata, the package lock
and project settings, not caches.
The repository's root `.gitignore` excludes Library, Temp, Logs, obj and Builds
at any depth.

## Run EditMode tests on Linux

From the repository root (see [Ship setup requirements](../Tools/ship/README.md)):

```sh
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh setup
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh activate
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh test editmode -testFilter YetiKit.Hands.Tests
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh test editmode
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh return
```

Setup and activate **once per session**, iterate using plain commands, then
return **exactly once at the end**, including on failures. Do not use return
traps or `UNITY_RETURN_ON_EXIT`. Credentials stay in the environment:
`UNITY_USERNAME` / `UNITY_PASSWORD` (or `USERNAME` / `PASSWORD` fallback).

For long imports/tests, background the command and wait for its PID:

```sh
mkdir -p Host/build
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh test editmode > Host/build/host-tests.log 2>&1 &
wait-log --pid $! 25
```

Results and logs are in ignored `Host/build/`. Use `-testFilter` for focused
iterations; run the full command once at the end. The normal EditMode runner
executes pure tests without graphics and a second Gfx-category pass.

## Generated starter integration (opt-in)

The [starter fixture](StarterTests/) lives outside `Assets` so the ordinary Host
compiles without generated code. With the Host editor closed, add these entries
once to the checkout's local Git exclude file (`git rev-parse --git-path info/exclude`):

```gitignore
/Host/Assets/Starter/
/Host/Assets/Starter.meta
/Host/Assets/StarterTests/
/Host/Assets/StarterTests.meta
```

From the repository root:

```sh
bash Host/StarterTests/stage.sh
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh test editmode -testCategory Gfx -testFilter YetiKit.Starter.HostTests
```

Staging runs the real generator twice in temporary directories, checks input
rejection and GUID isolation, then copies `Assets/Starter` with its generated
metadata and installs the test assembly. Run `bash Host/StarterTests/stage.sh
--check-only` on one line to validate the generator without staging or opening
Unity, even if the Host already has staged assets. It does not copy the generated package
manifest or project settings. The EditMode test bakes and reopens the sandbox in
an isolated subfolder of `Assets/StarterTests`, then briefly enters Play Mode to
check the sandbox's runtime bindings, drive the kit grab/release through XRI,
and verify one accepted hit per throw using synthetic contacts. It also checks
serialized rig wiring, controller/hand transitions, teleport landing rules and
snap turn using synthetic input and the real scene’s locomotion providers. It
also checks that the saved scene has no dev references, drives the desktop Lab
controls, and reloads the scene to verify local tuning and reset. A wrist fixture
uses synthetic controller and hand poses to select experiments, edit and reset,
and check that UI input does not cause room grabs or teleports. To render its
start and override states, set `YETIKIT_STARTER_LAB_CAPTURE` to an existing local
output directory and filter to `WristInputRoutesWithoutRoomActions`. No headset
or physical XR input device is required. Use the same activation/return procedure
as above.

The test deletes its bake; to remove staging (including any assets left by an
interrupted test), close the Host editor and run this from the repository root:

```sh
rm -rf -- Host/Assets/Starter Host/Assets/Starter.meta \
  Host/Assets/StarterTests Host/Assets/StarterTests.meta
```

Staging refuses to overwrite these paths. Clean and stage again after changes to
the generator or test source. Do not commit the staged copies.

## No player builds

[Ship configuration](yetikit.json) includes schema-required build fields pointing
to [HostBuild](Assets/Editor/HostBuild.cs). This editor method only logs that no
APK is produced. The Host is not an Android application; `apk` deliberately
fails its missing-output check rather than claiming a build succeeded.

CI does not activate Unity. [Cheap validation](../Tools/ci/check-unity.py) checks
script metadata, repository-wide GUID uniqueness and explicit opt-in assembly
references. Unity compilation and tests run in task VMs using the command above.
