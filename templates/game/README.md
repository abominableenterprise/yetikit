# Starter sandbox

This is the desktop editor scaffold for a consumer game, not a headset-ready project.
From a kit checkout, run `python3 templates/game/new-game.py --id <your reverse-DNS ID> --title <your title> --out <new directory>`, replacing all three arguments. The generator refuses placeholder identity and never overwrites an existing directory. It uses only Python’s standard library.

1. Open the generated directory in the Unity version recorded in `ProjectSettings/ProjectVersion.txt`.
2. After Unity imports the project, run `python3 verify-packages.py` from the generated root. Save any open untitled scene first (Unity requires a saved scene before it can create an additive scene). Use **Game → Build Starter Sandbox**, then open `Assets/Starter/Sandbox/Sandbox.unity`. On a clean project the menu imports the controller assets and finishes baking after Unity recompiles. It selects the scene on repeat use without overwriting your edits. Keep `Assets/Starter` and the imported controller assets under `Assets/Samples` with their metadata, along with `Packages/manifest.json` and the Unity-generated `Packages/packages-lock.json`.
3. Preview the room from the XR Origin camera. The ball and offset-grip prefab sit on a stand; thrown props make a short synthesized tone on the targets and the kit returns dropped props below the recovery plane.

### XR bindings

The baked rig uses the Input System and the kit’s hands and prop interaction. Each side uses its XR controller while tracked, otherwise it takes fresh XR Hands samples. If neither source is tracked, that side has no active interaction once the kit’s hand-grab dropout grace expires. A controller takeover or loss cancels the outgoing grab rather than throwing it. Each side shows an animated XR Interaction Toolkit Starter Assets controller when its controller is tracked, or joint markers when fresh hand poses are available. Neither model is shown when that side loses tracking.

- **Controllers:** grip to grab. Aim at a colored pad, then squeeze and release the trigger on the pad to teleport. Push the stick left or right for 30° snap turns.
- **Tracked hands:** use the kit’s near-grab gesture or Point & Pinch to teleport. For a snap turn, briefly hold a still fist with the thumb pointing sideways.
- **Scene wiring:** pads use XRI’s Default interaction layer; props and near grabbers use bit 1 of the XRI interaction mask. Reserve that bit if you name layers in the consumer project. These are interaction masks, not physics layers. An arc hitting the floor or an obstruction is not a valid landing.

The project uses one pinned kit revision and leaves the existing Unity and XRI versions unchanged. No OpenXR package, loader, controller profile or hand-tracking feature is configured: a consumer must configure a provider to receive live XR input. The bindings are tested in the Host with synthetic input only. Voice is off; there is no microphone capture or upload. The room, props, hand markers and tone are game-owned and get fresh asset GUIDs. The controllers come from the pinned package's [Starter Assets sample](https://docs.unity3d.com/Packages/com.unity.xr.interaction.toolkit@3.6/manual/samples-starter-assets.html) and keep their upstream GUIDs so the prefab references resolve. The package's `LICENSE.md` identifies the [Unity Companion License](https://unity.com/legal/licenses/unity-companion-license); the controller assets are imported into the generated project, not vendored under the kit's MIT license. If you already baked a sandbox, the builder will not upgrade it in place; keep your old assets and generate a fresh project to inspect or adopt the new rig.

The bake imports only the controller prefabs and their dependencies, not the demo rig, so it needs no new package pins. If the sample cannot be imported, restore the pinned package and move any incomplete or older Starter Assets import out of `Assets/Samples`, then rerun **Game → Build Starter Sandbox**. To deliberately use the old capsule visuals, choose **Game → Build Starter Sandbox (Placeholder Controllers)**; the bake logs a warning. Scripted bakes call `StarterControllerSample.Import()`, wait for compilation if it returns `true`, then call `SandboxBuilder.Build(output)`.

### Point & Pinch hand teleport

Point with your index extended and the other three fingers curled, palm facing down or forward. Hold the point for 0.10 s to preview an arc, pinch thumb to index to highlight a valid pad, then release the pinch while keeping the other fingers curled. Keep the aim on the pad through release. An open hand, lost tracking, or an invalid landing cancels the gesture. Only the first pinch owns the aim; holding props or reaching near props and UI takes priority.

`PointPinchPose` uses 0.30/0.42 index and 0.60/0.45 grip-finger enter/stay curl thresholds, with 0.15 s exit grace. `PointPinchGesture` closes below 1.5 cm and opens above 3 cm. `PointPinchPalm` and `AngularOneEuro` tune the shoulder offset and yaw/pitch smoothing. `PointPinchTeleport` controls the 0.75 s cooldown and 0.10 s post-grab quiet period. `TeleportAim` and `TeleportGround` handle the arc and landing. The baked hand arc uses its own 5 m/s launch speed and 9.8 m/s² gravity over 2.5 s and 24 segments. It shares the controller ray's physics filters, not its trajectory or input.

To switch hand teleport off, disable `PointPinchTeleport` on both hand objects in the baked rig. Leave the controller rays and locomotion providers enabled to keep controller teleport and snap turn.

### Desktop Starter Lab

In Play Mode, use the start panel to choose Compact (`snap-30`, 30°) or Wide (`snap-45`, 45°). The last explicit choice is marked but does not bypass the start panel. Use **−5°**, **+5°**, or **Reset** on the tuning panel. It shows the live snap angle and whether it differs from that experiment's default. Overrides are kept in local PlayerPrefs, separately for each ID, and reloaded when the experiment starts again. If saved tuning cannot be read, the panel reports that persistence is unavailable, uses the experiment default, and disables editing and reset for that experiment without changing its saved data. F8 hides or restores the panel.

For direct boot, launch the Editor (then enter Play Mode) or a desktop development player with `--starter-experiment snap-45` (or `snap-30`). In the Editor you can start from the open sandbox; to redirect from a different scene, include `Assets/Starter/Sandbox/Sandbox.unity` in the active build profile's scene list. A direct boot does not change the last explicit choice. The controls are created at runtime by `Game.Dev`; the saved room has no dev component references.

### XR Starter Lab

In the Editor or a dev-enabled player, the same controls appear above the tracked left wrist (or left controller). Aim the right controller's short pointer at a button and press and release the trigger on it, or touch it with a straight right index finger and pull back before poking again. The desktop panel and wrist share the active experiment and tuning, including the read-only warning for unreadable saved tuning. F8 still toggles only the desktop panel.

The wrist panel does not take over an existing prop hold. While pointing at it, the right controller cannot start a prop grab or teleport; a held grip or trigger stays captured until released. The tracked hand suppresses room gestures near the panel. These routes are checked with synthetic input; live behavior and placement comfort are pending hardware validation.

### Local photo snap

After choosing an experiment, press **Photo snap** on either panel. It takes a still from the sandbox camera and saves a `starter-photo-*.png` with a same-name `.json` sidecar in Unity’s `Application.persistentDataPath`. The sidecar records the active experiment, effective and default snap angles in degrees, whether an override is active, and whether tuning persistence is available. Both panels report success or a capture/storage error. Photos are never queued for upload; only the explicit button takes a still. Keep captures out of source control.

## Build a development or release player

In **File → Build Profiles**, switch to the desired desktop platform and add the baked `Assets/Starter/Sandbox/Sandbox.unity` to the scene list. Use **Build** with **Development Build** enabled for experiment boot, desktop and wrist tuning, and photo snap; disable it for release. The starter supplies `YETIKIT_DEV` for each development player build only. Do not add it to persistent project or profile defines.

The generated Build Profiles handler uses `StarterPlayerBuild.Build(BuildPlayerOptions)`; call that same entry point from build automation. Release leaves the playable room and authored snap turn, ignores the direct-boot argument, and omits the Lab controls and photo code. BuildAudit rejects forbidden assemblies before stripping and checks the final build report. For Android, it also inspects the packaged APK's permissions and rejects permissions that have not been explicitly allowed by the consumer. AABs and exported Gradle projects are not supported by this audit. The starter does not configure a live XR provider or validate an Android release; the build regression uses Linux desktop players in the synthetic Host.

## Optional Quest setup (consumer-owned)

The starter leaves XR provider setup to the generated project. If you target
Quest, use the following probe configuration as a starting point, not as kit
defaults or a supported version matrix:

- The probe used Unity `6000.6.6f1` with OpenXR `1.18.0`. In **XR Plug-in
  Management**, enable the OpenXR loader for **Android**.
- In the Android OpenXR settings, enable **Meta Quest Support**, add the
  **Oculus Touch Controller Profile**, and enable **Hand Tracking Subsystem**
  and **Meta Hand Tracking Aim**.
- In Android Player Settings, use **Linear** color space, **IL2CPP** scripting
  backend, **ARM64** target architecture, and **Vulkan** as the graphics API.
  Switch to the Android build profile and include the baked sandbox in its scene
  list. Use APK output for the release audit.

The probe APK installed on Quest and reached an active OpenXR session. That
confirms neither in-headset rendering nor live hand or controller input; verify
those separately on a headset. The probe's release build was rejected by
BuildAudit, not validated for release.

The fresh starter wires the pads and hand teleports with the same explicit XRI interaction mask. This does not rely on interaction-layer name lookups in a player. In a custom rig, set `teleportInteractionMask` to the pad mask or leave it at zero to resolve the `Teleport` layer by name. Preserve your custom layer names.

### Review Android release permissions

BuildAudit uses `aapt2` to check the packaged APK's merged manifest, so the
permissions may come from Unity, a plug-in, or a manifest in the project. The
probe audit rejected permissions named `INTERNET`, `HAND_TRACKING`, `OPENXR`,
`OPENXR_SYSTEM`, and `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` (the last is
prefixed by the application's ID). These are findings from one build, not a
list of required Quest permissions.

First trace each permission to its source and remove unused permissions by
adjusting the relevant features, dependencies, or manifests. Explicitly review
and record why each remaining permission is needed. In the generated project's
`Assets/Starter/Editor/StarterPlayerBuild.cs`, the release path currently calls
`BuildAuditHook.Enable(new BuildAuditRules())`, which denies all permissions by
default. In that consumer-owned release entry point, set
`BuildAuditRules.allowedPermissions` on the rules passed to `Enable` to only
those justified, full manifest names (exact matches, including your application
ID where applicable). Keep the default `forbiddenPermissions` policy (`"*"`),
assembly checks, strict mode, and `BuildAuditHook.Disable()` in `finally`. Do not
change the kit package or bypass the hook. Rebuild the release APK and rerun the
audit before treating it as a release candidate. See the
[BuildAudit guide](https://github.com/abominableenterprise/yetikit/blob/main/Packages/com.abominable.yetikit.quality/README.md#release-build-audit)
for the hook and SDK requirements.

## Verify a clean starter import

`python3 verify-packages.py --manifest-only` checks package sources before the
first import. After import, run `python3 verify-packages.py` without the flag:
it requires the Unity-generated lock and checks that all kit entries resolved
as Git packages at their manifest pins. Both modes reject local paths and
embedded packages; even the pre-import check validates an existing lock. This
is a package-source check, not an editor, device or signing doctor.

The generator pins all seven starter modules to the public `v0.3.2` tag.
The starter scripts themselves are copied into `Assets`, not fetched as a package.
For a cold import, start with a new project (no lock or `Library`), an empty
`UPM_CACHE_ROOT`, and no per-cache overrides (`UPM_CACHE_PATH`,
`UPM_NPM_CACHE_PATH`, `UPM_GIT_LFS_CACHE_PATH`). To check a compatible tag before
adoption, use a disposable generated copy with all kit URL fragments set to
that tag; leave the generator and your working project's pins alone.

### Linux Ship adapter

For a batch compile on Linux, run `Tools/ship/linux-unity.sh open` from the kit
checkout with `PROJECT` pointing at the generated root. Ship needs a root
`yetikit.json` even for `open`. This minimal example satisfies its schema;
use the version from `ProjectSettings/ProjectVersion.txt`:

```json
{
  "schema": 1,
  "unityVersion": "6000.6.6f1",
  "build": {
    "devMethod": "Consumer.Build.Development",
    "releaseMethod": "Consumer.Build.Release",
    "apkPath": "Builds/Android/consumer.apk"
  }
}
```

`open` does not call these build methods. For a cache-cold check, set `TASK_CACHE`
to a nonexistent command so Ship cannot restore `Library`, then verify the
package lock and compiled `Game.Starter`, `Game.Starter.Editor` and `Game.Dev`
assemblies. If using Ship for player builds later, supply real parameterless
consumer entry points that construct `BuildPlayerOptions` and call
`StarterPlayerBuild.Build`. Neither that Android adapter nor live XR setup is
needed for the desktop import check. See the [Ship guide](https://github.com/abominableenterprise/yetikit/blob/main/Tools/ship/README.md)
for wrapper setup and the consumer config schema.

### Lockfile, tools, CI and release notes

- **Lockfile:** generated on first Unity import, not shipped by the generator.
  Review and commit it with the manifest. After an intentional kit upgrade,
  resolve again and commit both files together.
- **Tools:** the generator does not vendor Ship. When adopting a compatible
  tag, use [`kit-bump.sh`](https://github.com/abominableenterprise/yetikit/blob/main/Tools/vendor/README.md)
  to switch all kit pins together and vendor `Tools/yetikit/` with its `VERSION`
  receipt. Before vendoring Ship, use `verify-packages.py` to check the
  generated package pins; [`kit-check.sh`](https://github.com/abominableenterprise/yetikit/blob/main/Tools/vendor/kit-check.sh)
  expects a tagged receipt.
- **CI:** the kit's [Ship shell suite](https://github.com/abominableenterprise/yetikit/blob/main/.github/workflows/ship.yml)
  exercises the generated verifier with synthetic inputs, not a remote Unity
  import. No consumer workflow is generated. On the consumer's CI, run the
  verifier against the committed lock, compile in the pinned Unity version,
  and check for lock drift. Add `kit-check.sh` once Ship is vendored from a tag.
- **Release notes:** not generated. Keep consumer-owned notes with the build
  record: summarize player-visible changes, record the kit revision and audit
  result, and distinguish desktop evidence from untested headset behavior.

## Day-0 checklist

1. **Clean-cache resolution and smoke/adapter tests:** use the clean-import procedure above. The kit Host runs synthetic smoke tests against staged starter assets; the generated project does not ship those tests.
2. **Doctor and safe install/verify:** the generated package-source check verifies the manifest and lock. Consumer install/launch tooling and separate headset validation are still pending.
3. **Title and build stamp:** check the generated title and application ID in Player Settings; a runtime build stamp is still pending.
4. **Hands and controllers:** verify both hands at ≥60 Hz and per-side switching to controllers. The Host covers synthetic switching; live tracking is pending OpenXR setup and separate headset validation.
5. **Throw and impact:** throw a prop at a target and check the impact event against the fixture band. Host checks the wiring and synthetic contacts; physical throws are pending separate headset validation.
6. **Locomotion:** check teleport and snap-turn events on the starter pads. Host uses synthetic input; live input and comfort are pending separate headset validation.
7. **Direct experiment boot:** launch with an experiment ID and check that it is selected without changing the last explicit choice. XR panel interaction is pending separate headset validation.
8. **Persistent tuning:** adjust the snap angle, restart, verify the experiment retains its override, then reset; check that capture context shows the effective value and override state. Host covers persistence and synthetic wrist input; live wrist use is pending separate headset validation.
9. **Local photo:** verify the PNG and context sidecar are saved locally with no upload or voice. Host uses synthetic captures; live XR capture is pending separate headset validation.
10. **Release and frame timing:** build with Development Build off and verify that BuildAudit passes without the Lab controls. The Host covers the desktop build and a synthetic leak. Follow the adoption steps above for the lockfile, tools, CI and release notes. Rendering and comfort defaults, frame-time recording and the Quest 2 floor remain pending separate headset validation.

Targets of ≤2 hours to local capture, ≤4 hours including release, and ≤10 minutes of headset verification are unmeasured until real use. Record queue, cold import and device wait separately.
