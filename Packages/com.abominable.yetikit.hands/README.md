# YetiKit Hands

## Tracked-hand primitives

Reference `YetiKit.Hands` from your assembly. Use `IHandTracking` (implemented by
`XrHandTracking`) to read wrist poses and joint positions in tracking space.
`HandCurls` converts those positions into per-joint and per-finger curls: 0 is
straight and 1 is fully curled. `HandShapeClassifier` and the gesture detectors
consume those measurements; callers decide what actions, if any, to perform.

The package includes grab, poke, turn and teleport gesture detection,
teleport arc sampling, and turn-input and audio-cue adapters. It does not
provide a scene rig or interactor. `HandShape.Bird` and `FingerCurls.MiddleOnly`
describe a middle-finger extension without assigning it an action.
