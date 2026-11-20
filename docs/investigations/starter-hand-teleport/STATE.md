# Starter hand teleport: red arc on Quest 3

## Status

A reported Quest 3 wear test of a generated starter at [`0289469`](https://github.com/abominableenterprise/yetikit/commit/0289469) could teleport with a forward index point, thumb raised to show the arc, then lowered to confirm. At [`d453494`](https://github.com/abominableenterprise/yetikit/commit/d453494), using the same probe-only OpenXR configuration, the hand arc appeared but stayed red when aiming toward a pad. Controller teleport, hand and controller visuals, and impact audio worked. No new device test was run for this investigation. This is part of [#263](https://github.com/abominableenterprise/yetikit/issues/263).

**The Host did not reproduce the red arc; the device root cause is not confirmed.** On unchanged production code at [`e5de7d9`](https://github.com/abominableenterprise/yetikit/commit/e5de7d9), the new `TrackedHandAimsAndTeleportsWithVisibleJoints` fixture passed. It generated and baked the room, reopened it in Play Mode, fed a tracked index point through `PlayerHand` and `HandTeleport` with the baked visual active, checked the valid arc and pad hit, then dropped the thumb and verified the rig moved. A deliberately different before-render sample moved the index marker without changing the gameplay tip. The synthetic provider does not model OpenXR sample delivery or the exact headset pose and room alignment.

## What the source and fixture rule out

- [#310](https://github.com/abominableenterprise/yetikit/pull/310) assigns the existing visual callback but does not change the gameplay wrist transform, pad masks, ray settings or kit pin. `HandTeleport` casts from the Dynamic index tip along the proximal-to-tip vector, not from a mesh, joint marker or wrist rotation. The render callback uses separate point and curl buffers and converts joint poses in the visual-only array. The baked marker hierarchy has renderers but no colliders; toggling it does not disable the hand root.
- [#309](https://github.com/abominableenterprise/yetikit/pull/309) changes the impact cue and falloff, not the geometry or teleport bindings. Controller success is consistent with correctly registered pads, but the controller and hand arcs start from different poses.
- Seeing the red arc means the hand gesture armed. The remaining question is why that live arc has no accepted landing. A visible pointing finger is not a landing prediction: the cast uses a gravity-driven path and stops at the first obstruction, or rejects a hit that fails the pad, normal, layer or UI checks. A marker can also show a newer pose than the one that drove the arc. These are diagnostic distinctions, not a diagnosis of the wear test.

## Capture on device

Bake the generated starter and install a development build made through the starter build entry point, which supplies `YETIKIT_DEV`. Release players do not contain the diagnostic. With the room open, run:

```sh
adb logcat -s Unity | grep StarterAim
```

Hold the index point with the thumb raised over each pad, then lower the thumb. Repeat with the controller from the same standing pose as a control. The logger emits changed snapshots only, at most five lines per second total across both sides. Vectors are world-space and rounded to three decimals. On thumb drop, `origin`, `forward`, and the hit describe the frozen arc; `wrist` and `indexTip` still describe the current Dynamic hand sample. When `handTracked=False`, those joint fields are not a current tracked pose.

For controllers, `xriValid` is the ray's XRI hit validity and `aimValid` also checks whether the teleport target can be selected. For hands, the starter draws a kit arc and submits the destination to XRI's provider without using an XRI ray interactor, so `xriValid=n/a`; read `aimValid` for the hand arc. `interactionMask` belongs to the hit interactable, `aimMask` is the expected interaction mask, and `gameObjectLayer` is the physics layer index. `firstBlocker` names a non-teleport collider that stopped the cast; it does not establish that the arc would have reached a pad behind it. Handle device traces locally and share only non-identifying excerpts.

## Next device check

Repeat the reported gesture on both fresh bakes from the same standing pose, using the same provider settings and recording only synthetic or non-identifying diagnostics. For a red frame, capture the Dynamic index tip and proximal positions in tracking and world space, the rendered marker pose, the ray settings, and the first rejected segment (collider or UI blocker, hit position and normal, or no hit). Record whether the thumb was already dropping, which freezes the aim. Check where the arc actually stops relative to the pad rather than where the finger appears to point. An A/B on the affected build with only the hand visual callback disabled can isolate render sampling without changing the XR setup or room. Replay the measured aim in Host before changing runtime behavior.
