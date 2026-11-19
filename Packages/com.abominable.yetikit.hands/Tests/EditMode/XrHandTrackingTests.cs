using System.Collections.Generic;
using NUnit.Framework;
using Unity.Collections;
using UnityEngine;
using UnityEngine.XR.Hands;
using UnityEngine.XR.Hands.ProviderImplementation;
using Flags = UnityEngine.XR.Hands.XRHandSubsystem.UpdateSuccessFlags;
using Phase = UnityEngine.XR.Hands.XRHandSubsystem.UpdateType;

namespace YetiKit.Hands.Tests
{
    public sealed class XrHandTrackingTests
    {
        const string ProviderId = "YetiKit synthetic hands";
        XRHandSubsystem subsystem;
        XrHandTracking tracking;

        [SetUp]
        public void SetUp()
        {
            var descriptors = new List<XRHandSubsystemDescriptor>();
            SubsystemManager.GetSubsystemDescriptors(descriptors);
            var descriptor = descriptors.Find(d => d.id == ProviderId);
            if (descriptor == null)
            {
                XRHandSubsystemDescriptor.Register(new XRHandSubsystemDescriptor.Cinfo
                {
                    id = ProviderId,
                    providerType = typeof(Provider),
                });
                SubsystemManager.GetSubsystemDescriptors(descriptors);
                descriptor = descriptors.Find(d => d.id == ProviderId);
            }
            subsystem = descriptor.Create();
            subsystem.Start();
            tracking = new XrHandTracking();
        }

        [TearDown]
        public void TearDown() => subsystem?.Destroy();

        [TestCase(0)]
        [TestCase(1)]
        public void CompletePointReadRejectsInsufficientCapacity(int length)
        {
            subsystem.TryUpdateHands(Phase.Dynamic);
            Assert.That(tracking.TryGetHand(true, new Vector3[length], out _), Is.False);
            Assert.That(tracking.TryGetHand(true, new Vector3[HandCurls.Points], out _), Is.True);
        }

        [Test]
        public void EmptyPoseReadFailsButTheSupportedWristAndPalmPrefixSucceeds()
        {
            subsystem.TryUpdateHands(Phase.Dynamic);
            Assert.That(tracking.TryGetJointPoses(true, new Pose[0]), Is.False);
            Assert.That(tracking.TryGetJointPoses(true, new Pose[XRHandJointID.Palm.ToIndex() + 1]), Is.True);
        }

        [Test]
        public void RootOnlyUpdateLeavesCachedJointPosesButCannotBeReadAsTracking()
        {
            var points = new Vector3[HandCurls.Points];
            var poses = new Pose[XrHandTracking.AllJoints];
            subsystem.TryUpdateHands(Phase.Dynamic);
            Assert.That(tracking.TryGetHand(true, points, out _), Is.True);
            Assert.That(tracking.TryGetJointPoses(true, poses), Is.True);

            var flags = subsystem.TryUpdateHands(Phase.BeforeRender);
            Assert.That(flags & (Flags.RightHandRootPose | Flags.RightHandJoints), Is.EqualTo(Flags.RightHandRootPose));
            Assert.That(subsystem.rightHand.GetJoint(XRHandJointID.Wrist).TryGetPose(out _), Is.True, "the provider left the cached joints untouched");
            Assert.That(subsystem.rightHand.isTracked, Is.False);
            Assert.That(tracking.TryGetHand(true, points, out _), Is.False);
            Assert.That(tracking.TryGetJointPoses(true, poses), Is.False);
            Assert.That(tracking.TryGetHand(false, points, out _), Is.True, "the other side is still fresh");
        }

        [Test]
        public void CachedPosesWithAnUnchangedDynamicTimestampGoThroughTrackingLoss()
        {
            var root = new GameObject("Hand");
            try
            {
                var hand = root.AddComponent<PlayerHand>();
                hand.Tracking = tracking;
                // Hook before the first Dynamic sample, as the runtime adapter does on first use.
                var points = new Vector3[HandCurls.Points];
                tracking.TryGetHand(true, points, out _);
                var sampleAt = Time.unscaledTime;
                subsystem.TryUpdateHands(Phase.Dynamic);
                hand.Tick(sampleAt);
                Assert.That(hand.HandTracked, Is.True);
                Assert.That(hand.Grab.Selecting, Is.True, "coincident tips start a synthetic pinch");
                Assert.That(hand.HandSampleAt, Is.EqualTo(sampleAt));
                hand.Tick(sampleAt + 0.01f);
                Assert.That(hand.HandTracked, Is.True, "the same sample can cover a short gap between updates");

                // No subsystem updates from here: the provider leaves the last complete poses cached.
                Assert.That(tracking.TryGetHand(true, points, out _), Is.True);
                var staleAt = sampleAt + HandGrabGesture.LostGrace;
                hand.Tick(staleAt);
                Assert.That(hand.Mode, Is.EqualTo(HandMode.None));
                Assert.That(hand.HandSampleAt, Is.EqualTo(float.NegativeInfinity));
                Assert.That(hand.Grab.InGrace, Is.True);
                hand.Tick(staleAt + HandGrabGesture.LostGrace + 0.01f);
                Assert.That(hand.Grab.Selecting, Is.False);
                Assert.That(hand.GrabberActive, Is.False);
            }
            finally { Object.DestroyImmediate(root); }
        }

        public sealed class Provider : XRHandSubsystemProvider
        {
            public override void Start() { }
            public override void Stop() { }
            public override void Destroy() { }

            public override void GetHandLayout(NativeArray<bool> joints)
            {
                for (var i = 0; i < joints.Length; i++) joints[i] = true;
            }

            public override Flags TryUpdateHands(Phase phase, ref Pose leftRoot, NativeArray<XRHandJoint> leftJoints,
                ref Pose rightRoot, NativeArray<XRHandJoint> rightJoints)
            {
                leftRoot = rightRoot = Pose.identity;
                Fill(leftJoints, Handedness.Left);
                if (phase == Phase.BeforeRender) return Flags.All & ~Flags.RightHandJoints;
                Fill(rightJoints, Handedness.Right);
                return Flags.All;
            }

            static void Fill(NativeArray<XRHandJoint> joints, Handedness side)
            {
                for (var i = 0; i < joints.Length; i++)
                    joints[i] = XRHandProviderUtility.CreateJoint(side, XRHandJointTrackingState.Pose,
                        XRHandJointIDUtility.FromIndex(i), Pose.identity);
            }
        }
    }
}
