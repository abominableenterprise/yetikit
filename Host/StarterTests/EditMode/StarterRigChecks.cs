using System.Collections;
using System.Linq;
using NUnit.Framework;
using Unity.XR.CoreUtils;
using UnityEditor;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using UnityEngine.InputSystem.XR;
using UnityEngine.SceneManagement;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;
using YetiKit.Hands;
using YetiKit.Interaction;
using static YetiKit.Starter.HostTests.StarterSandboxTests;

namespace YetiKit.Starter.HostTests
{
    internal static class StarterRigChecks
    {
        public static void AssertSavedRig(Scene scene, string output)
        {
            var origin = ComponentOn<XROrigin>(Root(scene, "XR Origin"));
            var camera = origin.Camera;
            Assert.That(camera, Is.Not.Null);
            Assert.That(camera.transform.parent.gameObject, Is.SameAs(origin.CameraFloorOffsetObject));
            Assert.That(camera.CompareTag("MainCamera"), Is.True);
            Assert.That(ComponentOn<TrackedPoseDriver>(camera.gameObject).positionInput.action.bindings.Single().path,
                Is.EqualTo("<XRHMD>/devicePosition"));
            var behaviors = scene.GetRootGameObjects().SelectMany(go => go.GetComponentsInChildren<Component>(true)).ToArray();
            Assert.That(behaviors.OfType<Camera>().Count(), Is.EqualTo(1));
            Assert.That(behaviors.OfType<AudioListener>().Count(), Is.EqualTo(1));
            Assert.That(ComponentOn<XRBodyTransformer>(origin.gameObject).xrOrigin, Is.SameAs(origin));
            var teleport = ComponentOn<TeleportationProvider>(origin.gameObject);
            var turn = ComponentOn<SnapTurnProvider>(origin.gameObject);
            Assert.That(turn.mediator, Is.SameAs(teleport.mediator));
            var hands = origin.GetComponentsInChildren<PlayerHand>();
            CollectionAssert.AreEquivalent(new[] { false, true }, hands.Select(h => h.RightHand));
            var padLayers = (int)ComponentOn<TeleportationArea>(Root(scene, "Left Teleport Pad")).interactionLayers;
            foreach (var hand in hands)
            {
                Assert.That(hand.transform.parent, Is.SameAs(camera.transform.parent));
                Assert.That(hand.controller.parent, Is.SameAs(hand.transform.parent));
                Assert.That(hand.controller.gameObject.activeSelf, Is.False);
                Assert.That(hand.grabber.hand, Is.SameAs(hand));
                var controllerGrab = ComponentOn<XRDirectInteractor>(hand.controller.gameObject);
                Assert.That(ControllerMotion.Of(controllerGrab.transform).hand, Is.SameAs(hand));
                Assert.That((int)controllerGrab.interactionLayers & padLayers, Is.Zero);
                var aim = ComponentOn<HandTeleport>(hand.gameObject);
                Assert.That(aim.head, Is.SameAs(camera.transform));
                Assert.That(aim.provider, Is.SameAs(teleport));
                Assert.That(aim.controllerRay.transform.IsChildOf(hand.controller), Is.True);
                Assert.That((int)aim.controllerRay.interactionLayers, Is.EqualTo(padLayers));
                Assert.That(AssetDatabase.GetAssetPath(aim.line.sharedMaterial), Is.EqualTo(output + "/Aim.mat"));
                var handTurn = ComponentOn<HandSnapTurn>(hand.gameObject);
                Assert.That(handTurn.provider, Is.SameAs(turn));
                Assert.That(handTurn.teleport, Is.SameAs(aim));
            }
        }

        public static IEnumerator DriveRig(Scene scene)
        {
            var origin = ComponentOn<XROrigin>(Root(scene, "XR Origin"));
            var hand = origin.GetComponentsInChildren<PlayerHand>().Single(h => h.RightHand);
            var other = origin.GetComponentsInChildren<PlayerHand>().Single(h => !h.RightHand);
            var turn = ComponentOn<HandSnapTurn>(hand.gameObject);
            var aim = ComponentOn<HandTeleport>(hand.gameObject);
            var grab = ComponentOn<XRDirectInteractor>(hand.controller.gameObject);
            var prop = ComponentOn<GrabbableProp>(Root(scene, "Offset Grip"));
            const string layout = "StarterTestController";
            InputSystem.RegisterLayout(@"{
                ""name"": ""StarterTestController"",
                ""extend"": ""XRController"",
                ""controls"": [
                    {""name"": ""triggerButton"", ""layout"": ""Button"", ""usage"": ""TriggerButton""},
                    {""name"": ""stick"", ""layout"": ""Vector2"", ""usage"": ""Primary2DAxis""}
                ]
            }");
            var device = (UnityEngine.InputSystem.XR.XRController)InputSystem.AddDevice(layout);
            try
            {
                InputSystem.SetDeviceUsage(device, "RightHand");
                Assert.That(hand.Mode, Is.EqualTo(HandMode.None));
                var tracking = new SyntheticHand();
                hand.Tracking = tracking;
                yield return null;
                Assert.That(hand.Mode, Is.EqualTo(HandMode.TrackedHand));
                Assert.That(hand.grabber.isActiveAndEnabled, Is.True);
                var interactable = prop.GetComponent<PropGrabInteractable>();
                grab.interactionManager.SelectEnter((IXRSelectInteractor)hand.grabber, interactable);
                Assert.That(prop.Held, Is.True);

                var position = hand.transform.parent.InverseTransformPoint(prop.transform.position);
                SetController(device, position, Quaternion.identity);
                yield return Frames(3);
                Assert.That(hand.Mode, Is.EqualTo(HandMode.Controller));
                Assert.That(other.Mode, Is.EqualTo(HandMode.None), "tracking is per side");
                Assert.That(Vector3.Distance(hand.controller.localPosition, position), Is.LessThan(0.001f));
                Assert.That(hand.grabber.isActiveAndEnabled || prop.Held || interactable.PendingLateRelease, Is.False);
                Assert.That(grab.isActiveAndEnabled, Is.True);
                Assert.That(aim.controllerRay.isActiveAndEnabled, Is.True);
                grab.interactionManager.SelectEnter((IXRSelectInteractor)grab, interactable);
                Assert.That(prop.Held, Is.True);

                var pad = Root(scene, "Right Teleport Pad");
                var area = ComponentOn<TeleportationArea>(pad);
                var teleports = 0;
                var controllerLanding = Vector3.zero;
                area.teleporting.AddListener(args => { teleports++; controllerLanding = args.teleportRequest.destinationPosition; });
                var rayStart = hand.transform.parent.InverseTransformPoint(pad.transform.position + Vector3.up);
                var rayRotation = Quaternion.Euler(90, 0, 0);
                yield return Frames(2); // Grabbing must disable the teleport ray.
                Assert.That(aim.controllerRay.isActiveAndEnabled, Is.False);
                grab.interactionManager.CancelInteractorSelection((IXRSelectInteractor)grab);
                SetController(device, rayStart, rayRotation);
                yield return Frames(3);
                SetController(device, rayStart, rayRotation, trigger: true);
                yield return Frames(3);
                Assert.That(aim.controllerRay.IsSelecting(area), Is.True);
                SetController(device, rayStart, rayRotation);
                yield return Frames(4);
                Assert.That(teleports, Is.EqualTo(1));
                AssertLanding(origin, controllerLanding);
                var beforeStick = origin.transform.rotation;
                SetController(device, rayStart, rayRotation, stick: new Vector2(0.2f, 0f));
                yield return Frames(3);
                Assert.That(origin.transform.rotation, Is.EqualTo(beforeStick), "Stick noise cannot turn the rig.");
                SetController(device, rayStart, rayRotation, stick: Vector2.left);
                yield return null;
                SetController(device, rayStart, rayRotation);
                yield return Frames(3);
                Assert.That(Quaternion.Angle(beforeStick, origin.transform.rotation), Is.EqualTo(30f).Within(0.01f));
                var afterStick = Time.time;
                yield return Until(() => Time.time - afterStick > turn.provider.debounceTime &&
                    turn.provider.locomotionState == LocomotionState.Idle);

                // Aim down over the other pad, now relative to the moved origin.
                var otherPad = Root(scene, "Left Teleport Pad");
                rayStart = hand.transform.parent.InverseTransformPoint(otherPad.transform.position + Vector3.up);
                SetController(device, rayStart, rayRotation);
                yield return Frames(3);
                var leftArea = ComponentOn<TeleportationArea>(otherPad);
                leftArea.teleporting.AddListener(_ => teleports++);
                SetController(device, rayStart, rayRotation, trigger: true);
                yield return Frames(3);
                Assert.That(aim.controllerRay.IsSelecting(leftArea), Is.True);
                var beforeLoss = origin.transform.position;
                InputSystem.RemoveDevice(device);
                yield return Frames(3);
                Assert.That(teleports, Is.EqualTo(1), "Losing tracking must not confirm an aimed teleport.");
                Assert.That(origin.transform.position, Is.EqualTo(beforeLoss));
                Assert.That(grab.isActiveAndEnabled || prop.Held || interactable.PendingLateRelease, Is.False);
                Assert.That(hand.Mode, Is.EqualTo(HandMode.TrackedHand));
                Assert.That(hand.grabber.isActiveAndEnabled, Is.True);

                Assert.That(turn.Input.Attached, Is.True);
                var beforeTurn = origin.transform.rotation;
                var headBefore = origin.Camera.transform.position;
                tracking.TurnPose = true;
                yield return Until(() => Quaternion.Angle(beforeTurn, origin.transform.rotation) >= 29.9f);
                Assert.That(Quaternion.Angle(beforeTurn, origin.transform.rotation), Is.EqualTo(30f).Within(0.01f));
                Assert.That(Vector3.Distance(headBefore, origin.Camera.transform.position), Is.LessThan(0.001f));
                Assert.That(turn.Input.Pending, Is.Zero);

                var floor = Root(scene, "Floor");
                Physics.SyncTransforms();
                aim.Aim.Cast(new Vector3(-2.6f, 1f, -1f), Vector3.down, aim.controllerRay, aim.TeleportLayerName);
                Assert.That(aim.HasTarget, Is.False, $"{floor.name} is not a landing area.");
                aim.Aim.Cast(pad.transform.position + Vector3.up, Vector3.down, aim.controllerRay, aim.TeleportLayerName);
                Assert.That(aim.HasTarget, Is.True);
                var destination = aim.Target.destinationPosition;
                Assert.That(pad.GetComponent<Collider>().bounds.Contains(destination), Is.True);
                Assert.That(destination.x, Is.EqualTo(pad.transform.position.x).Within(0.001f));
                Assert.That(aim.provider.QueueTeleportRequest(aim.Target), Is.True);
                yield return Frames(3);
                AssertLanding(origin, destination);
            }
            finally
            {
                if (device.added) InputSystem.RemoveDevice(device);
                InputSystem.RemoveLayout(layout);
            }
        }

        static void AssertLanding(XROrigin origin, Vector3 destination)
        {
            var head = origin.Camera.transform.position;
            Assert.That(Vector3.Distance(new Vector3(head.x, destination.y, head.z), destination), Is.LessThan(0.001f));
            Assert.That(head.y - destination.y, Is.EqualTo(1.6f).Within(0.001f));
        }

        static void SetController(UnityEngine.InputSystem.XR.XRController device, Vector3 position, Quaternion rotation,
            bool trigger = false, Vector2 stick = default)
        {
            using (StateEvent.From(device, out var state))
            {
                device.devicePosition.WriteValueIntoEvent(position, state);
                device.deviceRotation.WriteValueIntoEvent(rotation, state);
                device.trackingState.WriteValueIntoEvent(3, state);
                device.isTracked.WriteValueIntoEvent(1f, state);
                ((UnityEngine.InputSystem.Controls.ButtonControl)device["triggerButton"]).WriteValueIntoEvent(trigger ? 1f : 0f, state);
                ((UnityEngine.InputSystem.Controls.Vector2Control)device["stick"]).WriteValueIntoEvent(stick, state);
                InputSystem.QueueEvent(state);
            }
        }

        static IEnumerator Frames(int count)
        {
            for (var i = 0; i < count; i++) yield return null;
        }

        static IEnumerator Until(System.Func<bool> predicate)
        {
            var deadline = Time.realtimeSinceStartup + 4f;
            while (!predicate() && Time.realtimeSinceStartup < deadline) yield return null;
        }

        sealed class SyntheticHand : IHandTracking
        {
            public bool TurnPose;

            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = new Pose(new Vector3(0.3f, 1.25f, 0.15f), Quaternion.identity);
                for (var f = 0; f < FingerCurls.Fingers; f++)
                {
                    var offset = f * HandCurls.PointsPerFinger;
                    var p = wrist.position + Vector3.right * ((f - 2) * 0.02f);
                    var dir = Quaternion.identity;
                    points[offset] = p;
                    for (var i = 1; i < HandCurls.PointsPerFinger; i++)
                    {
                        if (TurnPose && i >= 2) dir *= Quaternion.AngleAxis(HandCurls.FullBend[f][i - 2], Vector3.right);
                        p += dir * Vector3.forward * 0.025f;
                        points[offset + i] = TurnPose && f == FingerCurls.Thumb
                            ? wrist.position + Vector3.right * (0.03f * i) : p;
                    }
                }
                if (TurnPose) points[0] = wrist.position;
                return true;
            }
        }
    }
}
