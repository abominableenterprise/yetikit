using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Hands;

namespace YetiKit.Hands.Tests
{
    public class PlayerHandTests
    {
        GameObject space;
        PlayerHand subscribedHand;

        [TearDown]
        public void TearDown()
        {
            if (subscribedHand) Lifecycle(subscribedHand, "OnDisable");
            Object.DestroyImmediate(space);
        }

        // Unity does not invoke these runtime messages for an ordinary component in EditMode.
        static void Lifecycle(PlayerHand hand, string message) =>
            typeof(PlayerHand).GetMethod(message, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(hand, null);

        [TestCase(false)]
        [TestCase(true)]
        public void SwitchesBetweenControllerAndTrackedWristWithoutAVisual(bool right)
        {
            var tracking = new FakeTracking();
            var hand = Build(right, tracking);
            Assert.That(hand.Visual, Is.Null);
            hand.controller.gameObject.SetActive(true);
            hand.Tick(0f);
            Assert.That(hand.Mode, Is.EqualTo(HandMode.Controller));
            AssertPose(hand.PalmPose, hand.controller.position, hand.controller.rotation);
            AssertPose(new Pose(hand.transform.position, hand.transform.rotation), hand.controller.position, hand.controller.rotation);
            hand.Report(0.3f, 0.7f);
            Assert.That(hand.Grip, Is.EqualTo(0.3f));
            Assert.That(hand.Trigger, Is.EqualTo(0.7f));

            hand.controller.gameObject.SetActive(false);
            hand.Tick(0.1f);
            Assert.That(tracking.LastRight, Is.EqualTo(right));
            Assert.That(hand.RightHand, Is.EqualTo(right));
            Assert.That(hand.HandTracked, Is.True);
            Assert.That(PlayerHand.IsPresent(hand.transform), Is.True);
            Assert.That(hand.Shape, Is.EqualTo(HandShape.Open));
            AssertPose(hand.WristPose, space.transform.TransformPoint(tracking.Wrist.position), space.transform.rotation * tracking.Wrist.rotation);
            AssertPose(new Pose(hand.transform.position, hand.transform.rotation), hand.WristPose.position, hand.WristPose.rotation);
            Assert.That(hand.TryIndexTip(out var tip), Is.True);
            Assert.That(tip, Is.EqualTo(space.transform.TransformPoint(tracking.Points[PinchStrength.IndexTip])));
            Assert.That(hand.Haptic(1f, 0.1f), Is.False);

            hand.controller.gameObject.SetActive(true);
            hand.Sync();
            Assert.That(hand.Mode, Is.EqualTo(HandMode.Controller));
            Assert.That(hand.TryIndexTip(out _), Is.False);
            Assert.That(hand.Trigger, Is.Zero, "no stale input on switching back");
            Assert.That(PlayerHand.Of(hand.controller.GetChild(0)), Is.SameAs(hand));
        }

        [Test]
        public void UsesPalmJointEvenWhenTheFullPoseArrayIsUnavailable()
        {
            var tracking = new JointTracking();
            var hand = Build(true, tracking);
            hand.Tick(0f);
            AssertPose(hand.PalmPose, space.transform.TransformPoint(tracking.Palm.position), space.transform.rotation * tracking.Palm.rotation);
            Assert.That(hand.TryJointPoses(new Pose[XrHandTracking.AllJoints]), Is.False);

            var visual = new RecordingVisual();
            hand.Visual = visual;
            tracking.FullPoses = true;
            hand.Tick(0.1f);
            Assert.That(visual.Joints, Has.Length.EqualTo(XrHandTracking.AllJoints));
            var poses = new Pose[XrHandTracking.AllJoints];
            Assert.That(hand.TryJointPoses(poses), Is.True);
            Assert.That(visual.Joints[XRHandJointID.Palm.ToIndex()], Is.EqualTo(hand.PalmPose));
            Assert.That(poses[XRHandJointID.Palm.ToIndex()], Is.EqualTo(hand.PalmPose));
        }

        [TestCase(false)]
        [TestCase(true)]
        public void PalmFallbackUsesTheFourProximalKnucklesAndTheWristBasis(bool right)
        {
            var tracking = new FakeTracking();
            var hand = Build(right, tracking);
            // Distinct proximal knuckles and a wrist not at the tracking-space origin.
            tracking.Points[6] = new Vector3(-0.08f, 0.02f, 0.10f);
            tracking.Points[11] = new Vector3(-0.02f, 0f, 0.06f);
            tracking.Points[16] = new Vector3(0.02f, 0.02f, 0.04f);
            tracking.Points[21] = new Vector3(0.04f, 0.04f, 0.04f);
            hand.Tick(0f);
            var mean = new Vector3(-0.01f, 0.02f, 0.06f);
            var fallback = Vector3.Lerp(tracking.Wrist.position, mean, 0.55f) - tracking.Wrist.rotation * Vector3.up * 0.025f;
            AssertPose(hand.PalmPose, space.transform.TransformPoint(fallback), hand.WristPose.rotation);
        }

        [Test]
        public void VisualReceivesPresenceAndRenderSamplesWithoutMovingGameplayRootOrDuplicatingListeners()
        {
            var tracking = new FakeTracking();
            var hand = Build(false, tracking);
            var visual = new RecordingVisual();
            hand.Visual = visual;
            subscribedHand = hand;
            Lifecycle(hand, "OnEnable");
            hand.Tick(0f);
            var dynamicWrist = hand.WristPose;
            Assert.That(visual.Wrist, Is.EqualTo(dynamicWrist));
            Assert.That(visual.Joints, Is.Null);
            Assert.That(visual.RingCurl, Is.LessThan(0.01f));
            Assert.That(PlayerHand.Side(false), Is.SameAs(hand));

            tracking.Wrist.position += Vector3.right * 0.02f;
            tracking.Points = HandShapeTests.Hand(0f, 1f, 1f, 1f, 1f);
            XrHandTracking.RaiseBeforeRender();
            Assert.That(visual.Poses, Is.EqualTo(2));
            Assert.That(visual.Wrist.position, Is.EqualTo(space.transform.TransformPoint(tracking.Wrist.position)));
            Assert.That(visual.RingCurl, Is.GreaterThan(0.9f));
            Assert.That(hand.WristPose, Is.EqualTo(dynamicWrist));
            Assert.That(hand.Shape, Is.EqualTo(HandShape.Open));
            Assert.That(hand.transform.position, Is.EqualTo(dynamicWrist.position));

            tracking.Tracked = false;
            hand.Tick(0.1f);
            hand.Tick(0.2f);
            Assert.That(hand.Present, Is.False);
            Assert.That(hand.Grip, Is.Zero);
            Assert.That(visual.Presence, Is.EqualTo(new[] { false, true, false }));
            tracking.Tracked = true;
            hand.Tick(0.3f);
            XrHandTracking.RaiseBeforeRender();
            Assert.That(visual.Poses, Is.EqualTo(4));
            Assert.That(visual.Presence, Is.EqualTo(new[] { false, true, false, true }));
            Assert.That(hand.Shape, Is.EqualTo(HandShape.Fist));
            Assert.That(hand.TryIndexTip(out _), Is.False);

            hand.controller.gameObject.SetActive(true);
            hand.Sync();
            hand.Report(0.25f, 0.8f);
            Assert.That(visual.ControllerInput, Is.EqualTo(new Vector2(0.25f, 0.8f)));
            Assert.That(visual.Presence, Has.Count.EqualTo(4), "the hand remains present across a direct modality switch");

            Lifecycle(hand, "OnDisable");
            Assert.That(PlayerHand.Side(false), Is.Null);
            Lifecycle(hand, "OnEnable");
            hand.controller.gameObject.SetActive(false);
            hand.Tick(0.4f);
            XrHandTracking.RaiseBeforeRender();
            Assert.That(visual.Poses, Is.EqualTo(6), "only one listener after re-enabling");
        }

        PlayerHand Build(bool right, FakeTracking tracking)
        {
            space = new GameObject("Tracking space");
            space.transform.SetPositionAndRotation(Vector3.one, Quaternion.Euler(25f, 70f, 0f));
            var hand = Child("Hand", space.transform).gameObject.AddComponent<PlayerHand>();
            hand.rightHand = right;
            hand.controller = Child("Controller", space.transform);
            hand.controller.SetLocalPositionAndRotation(Vector3.back, Quaternion.Euler(10f, 10f, 0f));
            Child("Controller interactor", hand.controller);
            hand.controller.gameObject.SetActive(false);
            hand.Tracking = tracking;
            return hand;
        }

        static Transform Child(string name, Transform parent)
        {
            var child = new GameObject(name).transform;
            child.SetParent(parent, false);
            return child;
        }

        static void AssertPose(Pose pose, Vector3 position, Quaternion rotation)
        {
            Assert.That(Vector3.Distance(pose.position, position), Is.LessThan(0.0001f));
            Assert.That(Quaternion.Angle(pose.rotation, rotation), Is.LessThan(0.05f));
        }

        class FakeTracking : IHandTracking
        {
            public bool Tracked = true;
            public bool LastRight;
            public Pose Wrist = new Pose(new Vector3(0.1f, 1.2f, 0.4f), Quaternion.Euler(-25f, 40f, 15f));
            public Vector3[] Points = HandShapeTests.Hand(0f, 0f, 0f, 0f, 0f);

            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                LastRight = right;
                wrist = Wrist;
                if (!Tracked) return false;
                Points.CopyTo(points, 0);
                return true;
            }
        }

        sealed class JointTracking : FakeTracking, IHandJointPoses
        {
            public bool FullPoses;
            public Pose Palm = new Pose(Vector3.forward, Quaternion.Euler(20f, 10f, 5f));

            public bool TryGetJointPoses(bool right, Pose[] poses)
            {
                if (!FullPoses && poses.Length > XRHandJointID.Palm.ToIndex() + 1) return false;
                for (var i = 0; i < poses.Length; i++) poses[i] = Pose.identity;
                poses[XRHandJointID.Wrist.ToIndex()] = Wrist;
                poses[XRHandJointID.Palm.ToIndex()] = Palm;
                return Tracked;
            }
        }

        sealed class RecordingVisual : IHandVisual
        {
            public readonly List<bool> Presence = new List<bool>();
            public Pose Wrist;
            public Pose[] Joints;
            public float RingCurl;
            public int Poses;
            public Vector2 ControllerInput;

            public void OnPresence(bool present) => Presence.Add(present);

            public void OnPose(Pose wrist, JointCurls curls, Pose[] joints)
            {
                Wrist = wrist;
                Joints = joints;
                RingCurl = curls[FingerCurls.Ring, 1];
                Poses++;
            }

            public void OnControllerInput(float grip, float trigger) => ControllerInput = new Vector2(grip, trigger);
        }
    }
}
