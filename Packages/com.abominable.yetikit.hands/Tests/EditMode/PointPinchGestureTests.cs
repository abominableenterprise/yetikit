using NUnit.Framework;

namespace YetiKit.Hands.Tests
{
    public class PointPinchGestureTests
    {
        static PointPinchResult Step(PointPinchGesture g, float gap = 0.05f, bool valid = true,
            bool ready = true, bool tracked = true, bool near = false, bool available = true, bool holding = false) =>
            g.Tick(tracked, holding, ready, near, gap, valid, available);

        static PointPinchGesture Pinched()
        {
            var g = new PointPinchGesture();
            Step(g);
            Assert.That(g.Aiming, Is.True);
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.True);
            return g;
        }

        [Test]
        public void IdleAimPinchReleaseTeleportsOnlyOnRelease()
        {
            var g = new PointPinchGesture();
            Assert.That(g.Aiming, Is.False);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.None));
            Assert.That(g.Aiming, Is.True);
            Assert.That(Step(g, 0.01f), Is.EqualTo(PointPinchResult.None));
            Assert.That(g.Pinching, Is.True);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.Teleport));
            Assert.That(g.Pinching, Is.False);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.None));
        }

        [Test]
        public void ReleaseUsesCurrentValidityRatherThanValidityAtPinchStart()
        {
            var g = new PointPinchGesture();
            Step(g, valid: false);
            Assert.That(Step(g, 0.01f, valid: false), Is.EqualTo(PointPinchResult.None));
            Assert.That(g.Pinching, Is.True);
            Assert.That(Step(g, valid: true), Is.EqualTo(PointPinchResult.Teleport));
        }

        [Test]
        public void ReleaseOverInvalidGroundCancels()
        {
            var g = Pinched();
            Assert.That(Step(g, valid: false), Is.EqualTo(PointPinchResult.Cancel));
            Assert.That(g.LastCancel, Is.EqualTo("no-target"));
            Assert.That(g.Aiming, Is.True);
            Assert.That(g.Pinching, Is.False);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.None), "an open sample cannot confirm a stale selection");
        }

        [Test]
        public void PalmUpCancelsEvenOnRelease()
        {
            var g = Pinched();
            Assert.That(Step(g, ready: false), Is.EqualTo(PointPinchResult.Cancel));
            Assert.That(g.LastCancel, Is.EqualTo("pose"));
            Assert.That(g.Aiming, Is.False);
        }

        [Test]
        public void HysteresisDoesNotReleaseOrRetriggerInTheGapBand()
        {
            var g = Pinched();
            foreach (var gap in new[] { 0.014f, 0.016f, PointPinchGesture.PinchRelease, 0.02f })
            {
                Assert.That(Step(g, gap), Is.EqualTo(PointPinchResult.None));
                Assert.That(g.Pinching, Is.True);
            }
            Assert.That(Step(g, 0.031f), Is.EqualTo(PointPinchResult.Teleport));
            Step(g, PointPinchGesture.PinchEnter);
            Assert.That(g.Pinching, Is.False);
            Step(g, 0.014f);
            Assert.That(g.Pinching, Is.True);
        }

        [Test]
        public void TrackingLossCancelsAndRequiresObservedRelease()
        {
            var g = Pinched();
            Assert.That(Step(g, tracked: false), Is.EqualTo(PointPinchResult.Cancel));
            Assert.That(g.LastCancel, Is.EqualTo("lost"));
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.False);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.None));
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.True);
        }

        [TestCase(true, true, "reach")]
        [TestCase(false, false, "busy")]
        public void UiOrOtherHandCancelsAndCannotRearmWhileStillPinched(bool near, bool available, string reason)
        {
            var g = Pinched();
            Assert.That(Step(g, 0.01f, near: near, available: available), Is.EqualTo(PointPinchResult.Cancel));
            Assert.That(g.LastCancel, Is.EqualTo(reason));
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.False);
            Step(g);
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.True);
        }

        [TestCase(float.NaN)]
        [TestCase(float.PositiveInfinity)]
        [TestCase(-0.01f)]
        public void MissingGapCannotConfirmOrCountAsAnOpenPinch(float gap)
        {
            var g = Pinched();
            Assert.That(Step(g, gap), Is.EqualTo(PointPinchResult.Cancel));
            Assert.That(g.LastCancel, Is.EqualTo("lost"));
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.False);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.None));
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.True);
        }

        [Test]
        public void HoldingCancelsEvenOnRelease()
        {
            var g = Pinched();
            Assert.That(Step(g, holding: true), Is.EqualTo(PointPinchResult.Cancel));
            Assert.That(g.LastCancel, Is.EqualTo("holding"));
            Assert.That(g.Aiming || g.Pinching, Is.False);
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.False, "the open sample while holding must not rearm");
        }

        [Test]
        public void ResetDropsSelectionAndRequiresAnotherOpenSample()
        {
            var g = Pinched();
            g.Reset();
            Assert.That(g.Aiming || g.Pinching, Is.False);
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.False);
            Assert.That(Step(g), Is.EqualTo(PointPinchResult.None));
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.True);
        }

        [Test]
        public void EnteringReadyPoseAlreadyPinchedDoesNotSelect()
        {
            var g = new PointPinchGesture();
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.False);
            Step(g);
            Step(g, 0.01f);
            Assert.That(g.Pinching, Is.True);
        }
    }
}
