# Starter sandbox

- Bake the scene, prefabs and materials: `Assets/Starter/Editor/SandboxBuilder.cs`.
- Bake the XR Origin, hand/controller interactors and pad locomotion: `Assets/Starter/Editor/SandboxRigBuilder.cs`.
- Switch each side to controller input only while tracked: `Assets/Starter/Runtime/ControllerTracking.cs`.
- Route thrown-prop contacts to room targets: `Assets/Starter/Runtime/SandboxBindings.cs`.
- Play the synthetic local tone: `Assets/Starter/Runtime/ImpactCue.cs`.
- Install dev-only direct boot and snap-turn tuning: `Assets/Starter/Dev/StarterLab.cs`.
- Preview the desktop start and tuning controls: `Assets/Starter/Dev/StarterLabPanel.cs`.
- Integration tests live in the kit Host and stage the generated files as a consumer would import them.
