using System.Collections;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Game.Dev;
using NUnit.Framework;
using Unity.XR.CoreUtils;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;
using UnityEngine.XR.Hands;
using YetiKit.Hands;
using YetiKit.Interaction;
using static YetiKit.Starter.HostTests.StarterRigChecks;
using static YetiKit.Starter.HostTests.StarterSandboxTests;

namespace YetiKit.Starter.HostTests
{
    internal static class StarterHandTeleportChecks
    {
        public static IEnumerator Drive(Scene scene)
        {
            var origin = ComponentOn<XROrigin>(Root(scene, "XR Origin"));
            var hand = origin.GetComponentsInChildren<PlayerHand>().Single(h => h.RightHand);
            var teleport = ComponentOn<PointPinchTeleport>(hand.gameObject);
            var pad = ComponentOn<BoxCollider>(Root(scene, "Right Teleport Pad"));
            var model = hand.transform.Find("Hand Visual");
            Assert.That(hand.Visual, Is.Not.Null, "Use the visual wired by the starter bake.");
            Assert.That(model, Is.Not.Null);
            Assert.That(teleport.controllerRay.isActiveAndEnabled, Is.False);
            // The hand must keep its original trajectory even if controller gravity is customized.
            teleport.controllerRay.acceleration = 18f;

            // Solve the shoulder ray and projectile together for an unobstructed hit near pad center.
            const float flight = 0.42f, handSpeed = 5f, handGravity = 9.8f, handTime = 2.5f;
            const int handSegments = 24;
            Assert.That(TeleportArc.MaxTime, Is.EqualTo(handTime));
            Assert.That(TeleportArc.Segments, Is.EqualTo(handSegments));
            var landing = pad.bounds.center + Vector3.up * pad.bounds.extents.y;
            var space = hand.transform.parent;
            var shoulder = teleport.head.position + Vector3.down * 0.20f + Vector3.right * 0.17f;
            var displaced = landing - shoulder + Vector3.up * (0.5f * handGravity * flight * flight);
            var direction = displaced.normalized;
            var midpoint = landing + Vector3.up * (0.5f * handGravity * flight * flight) -
                direction * (handSpeed * flight);
            var tracking = new PointingHand(space.InverseTransformPoint(midpoint), Quaternion.identity);
            var tip = midpoint + Vector3.right * 0.025f;
            hand.Tracking = tracking;
            var now = Time.time;
            hand.Tick(now);
            Assert.That(hand.HandTracked, Is.True);
            Assert.That(hand.Shape, Is.EqualTo(HandShape.Point));
            Assert.That(model.gameObject.activeInHierarchy, Is.True);
            Assert.That(teleport.Tick(now, false), Is.False);

            now += PointPinchPose.EnterDwell + 0.01f;
            hand.Tick(now);
            // Draw a different before-render sample without changing the Dynamic joints used by the arc.
            tracking.RenderOffset = 0.4f;
            XrHandTracking.RaiseBeforeRender();
            tracking.RenderOffset = 0f;
            var indexMarker = model.GetChild(XRHandJointID.IndexTip.ToIndex());
            Assert.That(Vector3.Distance(indexMarker.position, tip + space.up * 0.4f), Is.LessThan(0.001f));
            Assert.That(Vector3.Distance(hand.Joint(PinchStrength.IndexTip), tip), Is.LessThan(0.001f));
            Physics.SyncTransforms();
            Assert.That(teleport.Tick(now, false), Is.False, "Aiming alone cannot queue a teleport.");
            Assert.That(teleport.Aiming && teleport.line.enabled, Is.True);
            Assert.That(teleport.Aim.HasTarget, Is.True, "The arc must hit the pad with the baked hand visual active.");
            Assert.That(Vector3.Distance(teleport.AimRay.origin, midpoint), Is.LessThan(0.001f));
            // Check the rendered samples before the floor hit can truncate the arc.
            for (var i = 1; i <= 2; i++)
            {
                var t = i * handTime / handSegments;
                var expected = teleport.AimRay.GetPoint(handSpeed * t) + Vector3.down * (0.5f * handGravity * t * t);
                Assert.That(Vector3.Distance(teleport.line.GetPosition(i), expected), Is.LessThan(0.001f));
            }
            var destination = teleport.Aim.Target.destinationPosition;
            Assert.That(Vector3.Distance(destination, landing), Is.LessThan(0.04f));
            Assert.That(teleport.line.colorGradient.Evaluate(0f), Is.EqualTo(teleport.validColor.Evaluate(0f)));

            var diagnostic = ComponentOn<StarterAimDiagnostic>(Root(scene, "Sandbox Bindings"));
            var when = Time.unscaledTimeAsDouble;
            var originField = Regex.Escape(World(midpoint));
            var tipField = Regex.Escape(World(tip));
            var forwardField = Regex.Escape(World(direction));
            var hitField = Regex.Escape(World(destination));
            var wristField = Regex.Escape(World(hand.WristPose.position));
            LogAssert.Expect(LogType.Log, new Regex(
                $"^StarterAim side=right mode=hand gesture=aiming origin={originField} forward={forwardField} " +
                $"hit=True collider=\"Right Teleport Pad\" gameObjectLayer=0 interactionMask=0x00000001 aimMask=0x00000001 " +
                $"hitPoint={hitField} .*aimValid=True xriValid=n/a reason=\"none\" firstBlocker=\"n/a\" " +
                $"handTracked=True wrist={wristField} indexTip={tipField}$"));
            diagnostic.Sample(when);

            var blocker = new GameObject("Synthetic Occluder");
            try
            {
                blocker.transform.position = teleport.line.GetPosition(2);
                blocker.AddComponent<BoxCollider>().size = Vector3.one * 0.1f;
                Physics.SyncTransforms();
                Assert.That(teleport.Tick(now, false), Is.False);
                Assert.That(teleport.Aiming && !teleport.Aim.HasTarget, Is.True);
                var logCount = 0;
                void Count(string message, string stack, LogType type)
                {
                    if (type == LogType.Log && message.StartsWith("StarterAim ")) logCount++;
                }
                Application.logMessageReceived += Count;
                try
                {
                    diagnostic.Sample(when + 0.1);
                    Assert.That(logCount, Is.Zero, "Changes cannot bypass the rate limit.");
                    LogAssert.Expect(LogType.Log, new Regex("hit=True collider=\"Synthetic Occluder\" .*" +
                        "aimValid=False xriValid=n/a reason=\"not-a-teleport-interactable/first-collider\" firstBlocker=\"Synthetic Occluder\""));
                    diagnostic.Sample(when + 0.21);
                    diagnostic.Sample(when + 0.42);
                    Assert.That(logCount, Is.EqualTo(1), "An unchanged aim must not log again.");
                }
                finally { Application.logMessageReceived -= Count; }
            }
            finally { Object.DestroyImmediate(blocker); }
            Physics.SyncTransforms();
            Assert.That(teleport.Tick(now, false), Is.False);
            Assert.That(teleport.Aim.HasTarget, Is.True);

            tracking.Pinched = true;
            hand.Tick(now + 0.02f);
            Assert.That(teleport.Tick(now + 0.02f, false), Is.False, "The pinch only highlights the live target.");
            Assert.That(teleport.Pinching && teleport.reticle.activeInHierarchy, Is.True);
            Assert.That(teleport.reticle.transform.parent, Is.Null);
            Capture(origin.Camera, destination);
            tracking.Pinched = false;
            hand.Tick(now + 0.04f);
            Assert.That(teleport.Tick(now + 0.04f, false), Is.True, "Only the release queues a teleport.");
            Assert.That(teleport.reticle.activeSelf, Is.False);
            yield return Frames(4);
            var head = origin.Camera.transform.position;
            Assert.That(Vector3.Distance(new Vector3(head.x, destination.y, head.z), destination), Is.LessThan(0.001f));
        }

        static void Capture(Camera camera, Vector3 destination)
        {
            var path = System.Environment.GetEnvironmentVariable("YETIKIT_POINT_PINCH_CAPTURE");
            if (string.IsNullOrEmpty(path)) return;
            var screenshot = new GameObject("Synthetic capture camera").AddComponent<Camera>();
            screenshot.CopyFrom(camera);
            screenshot.transform.SetPositionAndRotation(camera.transform.position,
                Quaternion.LookRotation(destination - camera.transform.position));
            var target = RenderTexture.GetTemporary(768, 480, 24);
            var image = new Texture2D(target.width, target.height, TextureFormat.RGB24, false);
            var prior = RenderTexture.active;
            try
            {
                screenshot.targetTexture = target;
                screenshot.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0);
                image.Apply();
                File.WriteAllBytes(path, image.EncodeToPNG());
            }
            finally
            {
                RenderTexture.active = prior;
                screenshot.targetTexture = null;
                RenderTexture.ReleaseTemporary(target);
                Object.DestroyImmediate(screenshot.gameObject);
                Object.DestroyImmediate(image);
            }
        }

        static string World(Vector3 v) => System.FormattableString.Invariant($"({v.x:F3},{v.y:F3},{v.z:F3})");

        sealed class PointingHand : IHandTracking, IHandJointPoses
        {
            readonly Vector3[] points = new Vector3[HandCurls.Points];
            readonly Quaternion rotation;
            public float RenderOffset;
            public bool Pinched;

            public PointingHand(Vector3 tip, Quaternion rotation)
            {
                this.rotation = rotation;
                for (var f = 0; f < FingerCurls.Fingers; f++)
                {
                    var offset = f * HandCurls.PointsPerFinger;
                    var p = f == FingerCurls.Thumb ? Vector3.zero : new Vector3((f - 2) * 0.02f, 0f, 0.01f);
                    var dir = Quaternion.identity;
                    points[offset] = p;
                    for (var i = 1; i < HandCurls.PointsPerFinger; i++)
                    {
                        if (f >= FingerCurls.Middle && i >= 2)
                            dir *= Quaternion.AngleAxis(HandCurls.FullBend[f][i - 2], Vector3.right);
                        p += dir * Vector3.forward * 0.03f;
                        points[offset + i] = p;
                    }
                }
                var localTip = points[PinchStrength.IndexTip];
                for (var i = 0; i < points.Length; i++) points[i] = tip + rotation * (points[i] - localTip);
                points[PinchStrength.ThumbTip] = tip;
            }

            Vector3 Point(int i)
            {
                var spread = Pinched ? 0.005f : 0.025f;
                var side = i == PinchStrength.IndexTip ? spread : i == PinchStrength.ThumbTip ? -spread : 0f;
                return points[i] + Vector3.up * RenderOffset + rotation * Vector3.right * side;
            }

            public bool TryGetHand(bool right, Vector3[] into, out Pose wrist)
            {
                wrist = new Pose(Point(0), rotation);
                for (var i = 0; i < into.Length; i++) into[i] = Point(i);
                return right;
            }

            public bool TryGetJointPoses(bool right, Pose[] into)
            {
                for (var i = 0; i < into.Length; i++) into[i] = new Pose(Point(0), rotation);
                for (var i = 0; i < points.Length; i++)
                {
                    var slot = XrHandTracking.Joints[i].ToIndex();
                    if (slot < into.Length) into[slot] = new Pose(Point(i), rotation);
                }
                return right;
            }
        }
    }
}
