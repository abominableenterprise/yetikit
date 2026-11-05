# Unity test Host

Minimal Unity **6000.6.6f1** project for compiling and testing local kit packages.
Only core is referenced, with `testables` enabled. There are no scenes, XR or
render-pipeline packages. Unity generates metadata and project defaults on import;
commit required metadata, the package lock and project settings, not caches.
The repository's root `.gitignore` excludes Library, Temp, Logs, obj and Builds
at any depth.

## Run EditMode tests on Linux

From the repository root (see [Ship setup requirements](../Tools/ship/README.md)):

```sh
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh setup
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh activate
PROJECT="$PWD/Host" Tools/ship/linux-unity.sh test editmode -testFilter YetiKit.Core
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

## No player builds

[Ship configuration](yetikit.json) includes schema-required build fields pointing
to [HostBuild](Assets/Editor/HostBuild.cs). This editor method only logs that no
APK is produced. The Host is not an Android application; `apk` deliberately
fails its missing-output check rather than claiming a build succeeded.

CI does not activate Unity. [Cheap validation](../Tools/ci/check-unity.py) checks
script metadata, repository-wide GUID uniqueness and explicit opt-in assembly
references. Unity compilation and tests run in task VMs using the command above.
