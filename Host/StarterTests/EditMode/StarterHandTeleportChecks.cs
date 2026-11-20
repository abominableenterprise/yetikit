using System.Collections;
using System.Linq;
using NUnit.Framework;
using Unity.XR.CoreUtils;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.XR.Hands;
using YetiKit.Hands;
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
            var teleport = ComponentOn<HandTeleport>(hand.gameObject);
            var pad = ComponentOn<BoxCollider>(Root(scene, "Right Teleport Pad"));
            var model = hand.transform.Find("Hand Visual");
            Assert.That(hand.Visual, Is.Not.Null, "Use the visual wired by the starter bake.");
            Assert.That(model, Is.Not.Null);
            Assert.That(teleport.controllerRay.isActiveAndEnabled, Is.False);

            // Choose an unobstructed horizontal point whose projectile crosses the center of the pad.
            const float height = 1.2f;
            var landing = pad.bounds.center + Vector3.up * pad.bounds.extents.y;
            var range = teleport.controllerRay.velocity * Mathf.Sqrt(2f * (height - landing.y) / teleport.controllerRay.acceleration);
            const float reachX = 1.3f;
            var tip = new Vector3(landing.x - reachX, height, landing.z - Mathf.Sqrt(range * range - reachX * reachX));
            var space = hand.transform.parent;
            var direction = space.InverseTransformDirection(Vector3.ProjectOnPlane(landing - tip, Vector3.up).normalized);
            var tracking = new PointingHand(space.InverseTransformPoint(tip), Quaternion.LookRotation(direction));
            hand.Tracking = tracking;
            var now = Time.time;
            hand.Tick(now);
            Assert.That(hand.HandTracked, Is.True);
            Assert.That(hand.Shape, Is.EqualTo(HandShape.Point));
            Assert.That(model.gameObject.activeInHierarchy, Is.True);
            Assert.That(teleport.Tick(now, false), Is.False);

            now += HandTeleportGesture.ArmTime + 0.01f;
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
            Assert.That(teleport.HasTarget, Is.True, "The arc must hit the pad with the baked hand visual active.");
            var destination = teleport.Target.destinationPosition;
            Assert.That(Vector3.Distance(destination, landing), Is.LessThan(0.04f));
            Assert.That(teleport.line.colorGradient.Evaluate(0f), Is.EqualTo(teleport.validColor.Evaluate(0f)));

            tracking.ThumbDropped = true;
            hand.Tick(now + 0.02f);
            Assert.That(teleport.Tick(now + 0.02f, false), Is.True, "The thumb drop must queue the previewed target.");
            yield return Frames(4);
            var head = origin.Camera.transform.position;
            Assert.That(Vector3.Distance(new Vector3(head.x, destination.y, head.z), destination), Is.LessThan(0.001f));
        }

        sealed class PointingHand : IHandTracking, IHandJointPoses
        {
            readonly Vector3[] points = new Vector3[HandCurls.Points];
            readonly Quaternion rotation;
            public float RenderOffset;
            public bool ThumbDropped;

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
                points[ThumbHammer.ThumbTip] = new Vector3(-0.06f, 0.07f, 0.04f);
                var localTip = points[PinchStrength.IndexTip];
                for (var i = 0; i < points.Length; i++) points[i] = tip + rotation * (points[i] - localTip);
            }

            Vector3 Point(int i) => Vector3.up * RenderOffset + (ThumbDropped && i == ThumbHammer.ThumbTip
                ? points[ThumbHammer.IndexProximal] + rotation * Vector3.left * 0.01f : points[i]);

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
