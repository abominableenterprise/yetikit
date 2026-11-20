# Starter hand teleport: red arc on Quest 3

Part of [#263](https://github.com/abominableenterprise/yetikit/issues/263). **Device: pending candidate.**

## Device evidence and root cause

The [#316 diagnostic](https://github.com/abominableenterprise/yetikit/pull/316) in the Quest 3 development build at [`1388552`](https://github.com/abominableenterprise/yetikit/commit/1388552) saw the same result on both pads:

| Aim mode | Hit interaction mask | Aim mask | Outcome |
| --- | --- | --- | --- |
| Tracked hand | `0x00000001` | `0x00000000` | `aimValid=False`, `interaction-layer-mismatch` |
| Controller | `0x00000001` | `0x00000001` | `aimValid=True`, `xriValid=True` |

The hand arc reached the pad. The landing filter rejected it because its interaction mask was zero, not because of the gesture, cast pose, or visual mesh. The hand path called `InteractionLayerMask.GetMask("Default")`; the controller and pads used the serialized bit directly.

XRI 3.6.1 resolves names through `InteractionLayerSettings`. XR Core Utilities loads that settings object from `Resources`; if it cannot load the resource, it creates an instance. XRI sets the `Default` entry in `OnBeforeSerialize`, not on runtime creation. An instance without a populated name table therefore returns no layer for `Default`, so `GetMask` returns zero. The Editor can create and save settings during initialization. The Host already has a [Resources asset](../../../Host/Assets/XRI/Settings/Resources/InteractionLayerSettings.asset), which explains why the normal Host fixture resolved the name. Clean generations from both device revisions omit that asset before import. This verifies the missing-resource failure path, but the trace does not prove whether the failing APK lacked the asset, could not load it, or loaded an unpopulated table. The original APKs and generated project state were not compared.

## Why the earlier build could work

The reported wear test at [`0289469`](https://github.com/abominableenterprise/yetikit/commit/0289469) could show the hand arc and confirm a landing. Source comparison with `1388552` found the same kit pin, XRI version, hand lookup for `Default`, and bit-0 masks on the ray and pads. [`d1b5e47`](https://github.com/abominableenterprise/yetikit/commit/d1b5e47) was already in the earlier history and its locomotion changes were also in the pinned hands runtime; it did not change the mask lookup. The [visuals change](https://github.com/abominableenterprise/yetikit/pull/310) added a render-only hand callback and marker hierarchy without colliders; it did not change the gameplay joint sample or masks. The [audio change](https://github.com/abominableenterprise/yetikit/pull/309) did not touch teleport wiring. There is no source-level difference in mask resolution to explain the two outcomes. A layer table created and saved during one import but absent or unusable in the other player fits both the implementation and the logs; which project or build state differed remains unverified.

## Fix and regression coverage

- The generator supplies the same XRI Resources table as the Host. This fixes the lookup for fresh starters using the unchanged package pin; the template does not call a newer package API than its pin provides.
- The hands package also accepts a serialized numeric interaction mask. When set, it bypasses the name lookup; existing scenes keep their named fallback. The Host drives a hand at a valid pad with an unknown layer name: the named path rejects, a mismatched numeric mask rejects, and a matching numeric mask previews and queues the landing. This simulates the zero lookup without touching global settings. The generated starter fixture still checks the pinned name-based wiring with the baked joint visuals and diagnostic active.

## Capture on device

Build and install a development player from a fresh generation using the starter build entry point, which supplies `YETIKIT_DEV`. Release players do not contain the diagnostic. With the room open, run:

```sh
adb logcat -s Unity | grep StarterAim
```

Hold the point with the thumb raised over each pad, then lower the thumb. Repeat with the controller. Expect `interactionMask=0x00000001`, `aimMask=0x00000001`, `aimValid=True` on both paths and a completed landing on thumb drop. For controllers, `xriValid` is XRI's ray validity; for hands it is `n/a` because the hand arc submits directly to the teleport provider. On thumb drop the aim and hit fields describe the frozen arc, while the joint fields reflect the current Dynamic sample. If a fresh build still shows a zero mask, check whether the generated XRI Settings resource is in the player and loads with its `Default` entry, and compare those facts against the earlier builds if available. Handle device traces locally and share only non-identifying excerpts.
