using NUnit.Framework;

namespace YetiKit.Hands.Tests
{
    public sealed class HandGrabDropoutTests
    {
        [TestCase(-0.01f, false, true)]
        [TestCase(0f, false, true)]
        [TestCase(0.01f, false, false)]
        [TestCase(0.01f, true, false)]
        public void FirstTrackedFrameAppliesTheDropoutDeadline(float offset, bool fullFist, bool withinGrace)
        {
            var g = new HandGrabGesture();
            g.Tick(true, 1f, 0f, 0f, 0f);
            Assert.That(g.Armed, Is.True);
            g.Tick(false, 0f, 0f, 0f, 0.25f);
            var now = 0.25f + HandGrabGesture.LostGrace + offset;
            var curl = fullFist ? 1f : (HandGrabGesture.GripEnter + HandGrabGesture.GripStay) / 2f;
            g.Tick(true, curl, 0f, 1f, now);

            Assert.That(g.Selecting, Is.EqualTo(withinGrace || fullFist));
            Assert.That(g.Armed, Is.EqualTo(withinGrace));
            Assert.That(g.Trigger, Is.EqualTo(withinGrace ? 1f : 0f));
            Assert.That(g.StartedAt, Is.EqualTo(withinGrace ? 0f : fullFist ? now : float.NegativeInfinity));
        }

        [Test]
        public void ReacquisitionBetweenPinchThresholdsPreservesGrabAcrossRepeatedDropouts()
        {
            var gesture = new HandGrabGesture();
            var holdPinch = (HandGrabGesture.PinchEnter + HandGrabGesture.PinchStay) / 2f;
            gesture.Tick(true, 0f, HandGrabGesture.PinchEnter, 0f, 0f);

            // Recovery renews the grace period but not the selection start window.
            for (var i = 0; i < 2; i++)
            {
                var lostAt = 0.1f + i * 0.2f;
                gesture.Tick(false, 0f, 0f, 0f, lostAt);
                Assert.That(gesture.InGrace, Is.True);
                Assert.That(gesture.CanStart(lostAt), Is.False);

                gesture.Tick(true, 0f, holdPinch, 0f, lostAt + HandGrabGesture.LostGrace / 2f);
                Assert.That(gesture.InGrace, Is.False);
                Assert.That(gesture.Selecting, Is.True);
                Assert.That(gesture.StartedAt, Is.EqualTo(0f));
            }

            Assert.That(gesture.CanStart(0.4f), Is.False);
        }
    }
}
