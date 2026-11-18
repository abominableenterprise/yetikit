using NUnit.Framework;

namespace YetiKit.Hands.Tests
{
    /// <summary>Release latches and sample-independent deadlines for the teleport gesture.</summary>
    public class HandTeleportGestureTests
    {
        [TestCase(true)]
        [TestCase(false)]
        public void TrackingLossKeepsTheReleaseLatchUntilATrackedRelease(bool cancelWithPinch)
        {
            var g = Armed();
            var hammer = cancelWithPinch ? 0f : 1f;
            var pinch = cancelWithPinch ? 1f : 0f;
            Assert.That(g.Tick(true, true, true, hammer, pinch, false, 0.4f), Is.EqualTo(!cancelWithPinch));
            Assert.That(g.Aiming, Is.False);
            Assert.That(g.Busy, Is.True);

            // Untracked input reports zeroes; neither a short nor a long dropout is a physical release.
            foreach (var now in new[] { 0.41f, 1f })
            {
                Assert.That(g.Tick(false, false, false, 0f, 0f, false, now), Is.False);
                Assert.That(g.Busy, Is.True, "unknown tracking must not unblock the grab");
            }
            foreach (var now in new[] { 1.1f, 2f })
            {
                Assert.That(g.Tick(true, true, true, hammer, pinch, false, now), Is.False);
                Assert.That(g.Aiming, Is.False);
                Assert.That(g.Busy, Is.True, "the same held pinch/drop cannot become a grab on reacquisition");
            }
            g.Tick(true, false, false, 0f, 0f, false, 2.1f);
            Assert.That(g.Busy, Is.False, "a tracked release unblocks the grab");
            g.Tick(true, true, true, 0f, 0f, false, 2.2f);
            g.Tick(true, true, true, 0f, 0f, false, 2.2f + HandTeleportGesture.ArmTime + 0.01f);
            Assert.That(g.Aiming, Is.True, "a fresh gesture can arm after release");
        }

        [Test]
        public void TrackingLossCancelsAnActiveAimAndRestartsItsArmTime()
        {
            var g = Armed();
            g.Tick(true, true, true, 0.6f, 0f, false, 0.4f);
            Assert.That(g.Dropping, Is.True);
            Assert.That(g.Tick(false, false, false, 0f, 0f, false, 0.45f), Is.False);
            Assert.That(g.Aiming || g.Dropping || g.Busy, Is.False);
            Assert.That(g.Tick(true, true, true, 1f, 0f, false, 1f), Is.False, "no stale aim to confirm");
            g.Tick(true, true, true, 0f, 0f, false, 1.1f);
            Assert.That(g.Aiming, Is.False);
            g.Tick(true, true, true, 0f, 0f, false, 1.1f + HandTeleportGesture.ArmTime + 0.01f);
            Assert.That(g.Aiming, Is.True);
        }

        [TestCase(-0.01f, true)]
        [TestCase(0f, true)]
        [TestCase(0.01f, false)]
        public void TheFirstFullDropSampleMustRespectAnExistingHalfDropDeadline(float offset, bool confirms)
        {
            var g = Armed();
            const float start = 0.5f; // exactly representable, including the deadline
            Assert.That(g.Tick(true, true, true, 0.6f, 0f, false, start), Is.False);
            Assert.That(g.Dropping, Is.True);
            // No intervening half-drop sample: the first sample at/past the deadline is already fully down.
            Assert.That(g.Tick(true, false, true, 1f, 0f, false,
                start + HandTeleportGesture.HalfDropGrace + offset), Is.EqualTo(confirms));
            Assert.That(g.Aiming || g.Dropping, Is.False);
            Assert.That(g.Busy, Is.EqualTo(confirms), "an expired half drop cancels and frees the grab");
        }

        [Test]
        public void LiftingTheThumbBeforeTheDeadlineAllowsANewDrop()
        {
            var g = Armed();
            g.Tick(true, true, true, 0.6f, 0f, false, 0.4f);
            g.Tick(true, true, true, 0f, 0f, false, 0.5f);
            Assert.That(g.Dropping, Is.False);
            Assert.That(g.Tick(true, true, true, 1f, 0f, false, 1.1f), Is.True,
                "the abandoned half drop has no deadline on a fresh drop");
        }

        [TestCase(false)]
        [TestCase(true)]
        public void UiSuppressionCancelsPreviewWithoutClearingTheReleaseLatch(bool takeoverOnPinchFrame)
        {
            var g = Armed();
            if (!takeoverOnPinchFrame) g.Tick(true, true, true, 0f, 1f, false, .4f);
            Assert.That(g.Tick(true, true, true, 0f, 1f, false, .42f, suppressed: true), Is.False);
            Assert.That(g.Aiming, Is.False);
            Assert.That(g.Busy, Is.True);
            g.Tick(true, true, true, 0f, 1f, false, .44f);
            Assert.That(g.Busy, Is.True, "ownership ending is not a physical pinch release");
            g.Tick(true, true, true, 0f, 0f, false, .46f, suppressed: true);
            Assert.That(g.Busy, Is.False, "tracked release may clear the latch even while UI owns the hand");
            Assert.That(g.Aiming, Is.False);
        }

        static HandTeleportGesture Armed()
        {
            var g = new HandTeleportGesture();
            g.Tick(true, true, true, 0f, 0f, false, 0f);
            g.Tick(true, true, true, 0f, 0f, false, HandTeleportGesture.ArmTime + 0.01f);
            Assert.That(g.Aiming, Is.True);
            return g;
        }
    }
}
