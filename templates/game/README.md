# Starter sandbox

This is the desktop editor scaffold for a consumer game, not a headset-ready project.
From a kit checkout, run `python3 templates/game/new-game.py --id <your reverse-DNS ID> --title <your title> --out <new directory>`, replacing all three arguments. The generator refuses placeholder identity and never overwrites an existing directory. It uses only Python’s standard library.

1. Open the generated directory in the Unity version recorded in `ProjectSettings/ProjectVersion.txt`.
2. Save any open untitled scene first (Unity requires a saved scene before it can create an additive scene). Use **Game → Build Starter Sandbox**, then open `Assets/Starter/Sandbox/Sandbox.unity`. The menu selects the scene on repeat use without overwriting your edits. Commit `Assets/Starter` with metadata and the Unity-generated package lock.
3. Preview the room from the XR Origin camera. The ball and offset-grip prefab sit on a stand; thrown props make a short synthesized tone on the targets and the kit returns dropped props below the recovery plane.

### XR bindings

The baked rig uses the Input System and the kit’s hands and prop interaction. Each side uses its XR controller while tracked, otherwise it takes fresh XR Hands samples. If neither source is tracked, that side has no active interaction once the kit’s hand-grab dropout grace expires. A controller takeover or loss cancels the outgoing grab rather than throwing it.

- **Controllers:** grip to grab. Aim at a colored pad, then squeeze and release the trigger on the pad to teleport. Push the stick left or right for 30° snap turns.
- **Tracked hands:** use the kit’s near-grab gesture. To teleport, hold a forward index point with the thumb up until the arc appears, then drop the thumb. For a snap turn, briefly hold a still fist with the thumb pointing sideways. The kit handles the gesture thresholds and cooldown.
- **Scene wiring:** pads use XRI’s Default interaction layer; props and near grabbers use bit 1 of the XRI interaction mask. Reserve that bit if you name layers in the consumer project. These are interaction masks, not physics layers. An arc hitting the floor or an obstruction is not a valid landing.

The project uses one pinned kit revision and leaves the existing Unity and XRI versions unchanged. No OpenXR package, loader, controller profile or hand-tracking feature is configured: a consumer must configure a provider to receive live XR input. The bindings are tested in the Host with synthetic input only. Voice is off; there is no microphone capture or upload. The scene, prefabs, materials and tone belong to the generated project, not a package sample. Each generation gets fresh asset GUIDs. If you already baked a sandbox, the builder will not upgrade it in place; keep your old assets and generate a fresh project to inspect or adopt the new rig.

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

## Day-0 checklist

1. **Clean-cache resolution and smoke/adapter tests:** the kit Host runs synthetic smoke tests against staged starter assets; the generated project does not ship those tests. Remote package resolution from a cold cache and consumer adapter tests are pending.
2. **Doctor and safe install/verify:** the starter does not ship doctor or install tooling. Safe install and launch are pending consumer tooling and separate headset validation.
3. **Title and build stamp:** check the generated title and application ID in Player Settings; a runtime build stamp is still pending.
4. **Hands and controllers:** verify both hands at ≥60 Hz and per-side switching to controllers. The Host covers synthetic switching; live tracking is pending OpenXR setup and separate headset validation.
5. **Throw and impact:** throw a prop at a target and check the impact event against the fixture band. Host checks the wiring and synthetic contacts; physical throws are pending separate headset validation.
6. **Locomotion:** check teleport and snap-turn events on the starter pads. Host uses synthetic input; live input and comfort are pending separate headset validation.
7. **Direct experiment boot:** launch with an experiment ID and check that it is selected without changing the last explicit choice. XR panel interaction is pending separate headset validation.
8. **Persistent tuning:** adjust the snap angle, restart, verify the experiment retains its override, then reset; check that capture context shows the effective value and override state. Host covers persistence and synthetic wrist input; live wrist use is pending separate headset validation.
9. **Local photo:** verify the PNG and context sidecar are saved locally with no upload or voice. Host uses synthetic captures; live XR capture is pending separate headset validation.
10. **Release and frame timing:** build with Development Build off and verify that BuildAudit passes without the Lab controls. The Host covers the desktop build and a synthetic leak. The consumer still needs rendering and comfort defaults, a pinned lockfile, vendored Ship tools, CI and release notes. Frame-time recording and the Quest 2 floor are pending separate headset validation.

Targets of ≤2 hours to local capture, ≤4 hours including release, and ≤10 minutes of headset verification are unmeasured until real use. Record queue, cold import and device wait separately.
