# Starter sandbox

- Verify remote package sources before and after first import: `verify-packages.py` at the project root.

- Bake the scene, prefabs and materials: `Assets/Starter/Editor/SandboxBuilder.cs`.
- Configure per-build dev defines and audit release players: `Assets/Starter/Editor/StarterPlayerBuild.cs`.
- Bake the XR Origin, hand/controller interactors and pad locomotion: `Assets/Starter/Editor/SandboxRigBuilder.cs`.
- Switch each side to controller input only while tracked: `Assets/Starter/Runtime/ControllerTracking.cs`.
- Route thrown-prop contacts to room targets: `Assets/Starter/Runtime/SandboxBindings.cs`.
- Play the synthetic local tone: `Assets/Starter/Runtime/ImpactCue.cs`.
- Install dev-only direct boot and snap-turn tuning: `Assets/Starter/Dev/StarterLab.cs`.
- Log changed teleport aim snapshots in dev builds: `Assets/Starter/Dev/StarterAimDiagnostic.cs`.
- Render local stills and save them with tuning context: `Assets/Starter/Dev/StarterPhoto.cs`.
- Share start, tuning and photo controls between desktop and wrist: `Assets/Starter/Dev/StarterLabPanel.cs`.
- Attach the dev-only wrist UI and route pointing or poking before room selections: `Assets/Starter/Dev/StarterWristPanel.cs`.
- Integration tests live in the kit Host and stage the generated files as a consumer would import them.
