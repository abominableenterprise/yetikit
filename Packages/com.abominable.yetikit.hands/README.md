# YetiKit Hands

## Tracked-hand primitives

Reference `YetiKit.Hands` from your assembly. Use `IHandTracking` (implemented by
`XrHandTracking`) to read wrist poses and joint positions in tracking space.
`HandCurls` converts those positions into per-joint and per-finger curls: 0 is
straight and 1 is fully curled. `HandShapeClassifier` and the gesture detectors
consume those measurements; callers decide what actions, if any, to perform.

The package includes grab, poke, turn and teleport gesture detection,
teleport arc sampling, and turn-input and audio-cue adapters. It does not
provide a scene rig. `HandShape.Bird` and `FingerCurls.MiddleOnly` describe a
middle-finger extension without assigning it an action.

## Hand locomotion and wrist input

- Set `HandTeleport.hand`, `head` (the XR camera), and the rig's XRI
  `TeleportationProvider`. Give it a line and reticle to show the preview.
  Assign the controller's teleport ray to share its arc settings. Configure
  the teleport **interaction** layer (default `Teleport`) in the project and
  use it on the teleportation areas.
- The hands share an aim lease through their tracking-space parent. Assign the
  same `rig` on both components if their parents differ. External aim adapters
  can claim the same lease and supply an optional preemption policy. Set
  `Aim.Blocker` or `Aim.LandingAllowed` for additional restrictions. Add active
  world-space panel rects to `HandUiGuard.Rects` and remove them when unregistered.
- Wire `HandSnapTurn` to the same hand, camera, and teleport adapter plus the
  rig's `SnapTurnProvider`. For code-assigned references, call `Attach()`
  after wiring so the tracked-hand pulse uses the correct controller reader.
- Place `WristButton` under the wearing hand, assign the wearing/pressing
  hands, and subscribe to `Pressed` in code or `onPressed` in the Inspector.
