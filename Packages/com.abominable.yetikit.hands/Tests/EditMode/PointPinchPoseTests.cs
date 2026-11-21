using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Hands.Tests
{
    public class PointPinchPoseTests
    {
        const float BoundaryMargin = 0.001f;

        static bool Step(PointPinchPose pose, FingerCurls curls, float now) =>
            pose.Tick(Vector3.down, Vector3.forward, curls, now);

        static PointPinchPose Arm()
        {
            var pose = new PointPinchPose();
            Assert.That(Step(pose, FingerCurls.Point, 0f), Is.False);
            Assert.That(Step(pose, FingerCurls.Point, PointPinchPose.EnterDwell), Is.True);
            return pose;
        }

        [Test]
        public void EntryRequiresUninterruptedStrictPointDwell()
        {
            var pose = new PointPinchPose();
            var loose = FingerCurls.Point;
            loose.middle = 0.5f;
            Assert.That(Step(pose, loose, 0f), Is.False);
            Assert.That(Step(pose, loose, 0.2f), Is.False);
            Assert.That(Step(pose, FingerCurls.Point, 0.3f), Is.False);
            Assert.That(Step(pose, loose, 0.39f), Is.False);
            const float resumed = 0.4f;
            Assert.That(Step(pose, FingerCurls.Point, resumed), Is.False);
            Assert.That(Step(pose, FingerCurls.Point, resumed + PointPinchPose.EnterDwell + BoundaryMargin), Is.True);
        }

        [Test]
        public void BentIndexAndLooseCurlsCanConfirmAfterStrictEntry()
        {
            var pose = Arm();
            var pinch = new FingerCurls { index = 0.5f, middle = 0.5f, ring = 0.5f, pinky = 0.5f };
            Assert.That(pose.Tick(Vector3.down, Vector3.forward, pinch, 0.2f, pinching: true), Is.True);
            Assert.That(pose.Tick(Vector3.down, Vector3.forward, pinch, 0.4f, pinching: true), Is.True);
            Assert.That(Step(pose, pinch, 0.5f), Is.True);
            Assert.That(Step(pose, pinch, 0.66f), Is.False, "An unpinched point uses the straight stay threshold.");
            Assert.That(PointPinchPose.CanConfirm(pinch), Is.True);
        }

        [TestCase(FingerCurls.Middle)]
        [TestCase(FingerCurls.Ring)]
        [TestCase(FingerCurls.Pinky)]
        public void ExitGraceKeepsPreviewButOpeningAnyGripFingerPreventsConfirmation(int finger)
        {
            var pose = Arm();
            var lostPoint = FingerCurls.Point;
            lostPoint[finger] = 0f;
            const float lostAt = 0.2f;
            var deadline = lostAt + PointPinchPose.ExitDwell;
            Assert.That(Step(pose, lostPoint, lostAt), Is.True);
            Assert.That(Step(pose, lostPoint, deadline - BoundaryMargin), Is.True);
            Assert.That(PointPinchPose.CanConfirm(lostPoint), Is.False);
            Assert.That(Step(pose, lostPoint, deadline), Is.False);
            Assert.That(Step(pose, FingerCurls.Point, 0.4f), Is.False, "re-entry requires fresh dwell");
        }

        [Test]
        public void RecoveringThePoseBeforeDeadlineClearsExitGrace()
        {
            var pose = Arm();
            Assert.That(Step(pose, FingerCurls.Open, 0.2f), Is.True);
            Assert.That(Step(pose, FingerCurls.Point, 0.3f), Is.True);
            Assert.That(Step(pose, FingerCurls.Open, 0.4f), Is.True);
        }

        [Test]
        public void PalmRejectionIsImmediateAndRestartsEntryDwell()
        {
            var pose = Arm();
            Assert.That(pose.Tick(Vector3.up, Vector3.forward, FingerCurls.Point, 0.2f), Is.False);
            Assert.That(Step(pose, FingerCurls.Point, 0.3f), Is.False);
            Assert.That(Step(pose, FingerCurls.Point, 0.41f), Is.True);
            pose.Reset();
            Assert.That(Step(pose, FingerCurls.Point, 0.42f), Is.False);
        }

        [Test]
        public void ForwardAndDownPalmsAllowNaturalIndexBend()
        {
            Assert.That(PointPinchPose.Ready(Vector3.forward, Vector3.forward,
                PointPinchPose.MaxIndexCurl - BoundaryMargin), Is.True);
            Assert.That(PointPinchPose.Ready(Vector3.down, Vector3.forward, 0f), Is.True);
        }

        [Test]
        public void UpFaceAndMissingPalmNormalsAreRejected()
        {
            foreach (var normal in new[] { Vector3.up, Vector3.back, Vector3.zero })
                Assert.That(PointPinchPose.Ready(normal, Vector3.forward, 0f), Is.False, normal.ToString());
        }

        [Test]
        public void PalmUpBoundaryIsExclusive()
        {
            Vector3 Normal(float up) => new Vector3(Mathf.Sqrt(1f - up * up), up, 0f);
            Assert.That(PointPinchPose.Ready(Normal(PointPinchPose.MaxPalmUp - BoundaryMargin), Vector3.forward, 0f), Is.True);
            Assert.That(PointPinchPose.Ready(Normal(PointPinchPose.MaxPalmUp), Vector3.forward, 0f), Is.False);
        }

        [Test]
        public void FaceBoundaryFollowsHeadForwardAndIsExclusive()
        {
            Vector3 Normal(float toward) => new Vector3(-toward, 0f, Mathf.Sqrt(1f - toward * toward));
            Assert.That(PointPinchPose.Ready(Normal(PointPinchPose.MaxPalmTowardFace - BoundaryMargin), Vector3.right, 0f), Is.True);
            Assert.That(PointPinchPose.Ready(Normal(PointPinchPose.MaxPalmTowardFace), Vector3.right, 0f), Is.False);
        }

        [Test]
        public void PartiallyCurledFistIndexNeverReadiesTeleport() =>
            Assert.That(PointPinchPose.Ready(Vector3.down, Vector3.forward, 0.7f), Is.False);

        [Test]
        public void CurledIndexBoundaryIsExclusive() =>
            Assert.That(PointPinchPose.Ready(Vector3.down, Vector3.forward, PointPinchPose.MaxIndexCurl), Is.False);
    }
}
