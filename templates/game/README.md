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

The project uses one pinned kit revision and leaves the existing Unity and XRI versions unchanged. No OpenXR package, loader, controller profile or hand-tracking feature is configured: a consumer must configure a provider to receive live XR input. The bindings are tested in the Host with synthetic input only. No dev boot, mic, capture or upload is configured; voice is off. The scene, prefabs, materials and tone belong to the generated project, not a package sample. Each generation gets fresh asset GUIDs. If you already baked a sandbox, the builder will not upgrade it in place; keep your old assets and generate a fresh project to inspect or adopt the new rig.

## Remaining day-0 checklist

1. **Clean-cache resolution and smoke/adapter tests:** Host tests cover generated scripts and scene wiring; verify resolution from the generated project’s remote pins and add consumer adapter tests.
2. **Doctor and safe install/verify:** pending release tooling and separately authorized hardware validation.
3. **Title and build stamp:** title and application ID are stamped into settings; runtime stamp and game build entry point remain.
4. **Hands and controllers:** the rig and per-side switching are wired; configure OpenXR and verify both hands at ≥60 Hz on separately authorized hardware.
5. **Throw/impact:** starter targets and cue are wired; validate the physical throw/impact event band on hardware.
6. **Locomotion:** pads and snap turn are wired and motion is checked in the synthetic Host; live inputs and comfort remain unverified.
7. **Direct experiment boot:** wire dev-only selection and the start/wrist panels.
8. **Persistent tuning:** wire the tuning panel and per-experiment defaults, persistence, reset and override visibility in local capture context.
9. **Local photo:** wire and verify local-only photo snap; no upload or voice by default.
10. **Release and frame timing:** wire dev stripping and BuildAudit; finish project rendering/comfort defaults, pinned lock, vendored Ship tools, CI and release notes; measure frame time on separately authorized hardware, including the Quest 2 floor.

Targets of ≤2 hours to local capture, ≤4 hours including release, and ≤10 minutes of headset verification are unmeasured until real use. Record queue, cold import and device wait separately.
