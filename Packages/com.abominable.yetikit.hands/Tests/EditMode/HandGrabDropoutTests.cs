using NUnit.Framework;

namespace YetiKit.Hands.Tests
{
    public sealed class HandGrabDropoutTests
    {
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
