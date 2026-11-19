using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class LateReleaseTests
    {
        [TestCase(true)]
        [TestCase(false)]
        public void FastThrowWaitsForThePostReleasePeakThenFinishesOnDeceleration(bool peaksOnFirstSample)
        {
            var pending = new LateRelease(0f, Vector3.forward * 3f);
            var peak = new Vector3(2f, 1f, 6f);
            Assert.That(pending.ShouldWait(0f), Is.True);

            // The first sample can carry the entire post-release gain, or the swing can keep accelerating.
            pending.Add(.02f, peaksOnFirstSample ? peak : Vector3.forward * 4f);
            Assert.That(pending.ShouldWait(.02f), Is.True);
            Assert.That(pending.TryComplete(.02f, out _), Is.False);
            if (!peaksOnFirstSample)
            {
                pending.Add(.04f, peak);
                Assert.That(pending.ShouldWait(.04f), Is.True);
            }

            pending.Add(.06f, Vector3.right * 4f);
            Assert.That(pending.ShouldWait(.06f), Is.False);
            Assert.That(pending.TryComplete(.06f, out var chosen), Is.True);
            Assert.That(chosen, Is.EqualTo(peak));
        }

        [Test]
        public void AGentleDropDoesNotBecomeAThrowAfterTheHandMovesAway()
        {
            var release = Vector3.down * .1f;
            var pending = new LateRelease(0f, release);
            Assert.That(pending.ShouldWait(0f), Is.False);
            pending.Add(.02f, Vector3.right * 3f);
            Assert.That(pending.TryComplete(.02f, out var chosen), Is.True);
            Assert.That(chosen, Is.EqualTo(release));
        }

        [Test]
        public void ASlowingThrowFinishesWithoutWaitingForTheTimeCap()
        {
            var release = Vector3.forward * 2.5f;
            var pending = new LateRelease(0f, release);
            Assert.That(pending.ShouldWait(0f), Is.True);
            pending.Add(.02f, Vector3.forward * 2f);
            Assert.That(pending.ShouldWait(.02f), Is.False);
            Assert.That(pending.TryComplete(.02f, out var chosen), Is.True);
            Assert.That(chosen, Is.EqualTo(release));
        }

        [Test]
        public void AContinuouslyAcceleratingThrowHasAFiniteWaitAndIgnoresLaterSamples()
        {
            var pending = new LateRelease(0f, Vector3.forward * 4f);
            Assert.That(pending.ShouldWait(0f), Is.True);
            pending.Add(.03f, Vector3.forward * 5f);
            Assert.That(pending.ShouldWait(.03f), Is.True);
            Assert.That(pending.ShouldWait(LateRelease.Max), Is.False, "never hold a released prop indefinitely");
            pending.Add(LateRelease.Max + .01f, Vector3.forward * 20f);
            Assert.That(pending.TryComplete(LateRelease.Max + .01f, out var chosen), Is.True);
            Assert.That(chosen, Is.EqualTo(Vector3.forward * 5f));
            Assert.That(pending.TryComplete(LateRelease.Max + .02f, out _), Is.False, "a throw must complete only once");
        }

        [Test]
        public void RegrabCancelsThePendingThrowInsteadOfLaunchingItLater()
        {
            var pending = new LateRelease(0f, Vector3.forward * 5f);
            pending.Add(.03f, Vector3.forward * 8f);
            pending.Cancel();
            Assert.That(pending.ShouldWait(.04f), Is.False);
            pending.Add(.06f, Vector3.forward * 12f);
            Assert.That(pending.TryComplete(.25f, out _), Is.False, "no stale launch after regrab");
        }

        [Test]
        public void FastButAlreadySlowingAtGripOpenLaunchesImmediately()
        {
            var pending = new LateRelease(0f, Vector3.forward * 4f, previousSpeed: 6f);
            Assert.That(pending.ShouldWait(0f), Is.False);
            Assert.That(pending.TryComplete(0f, out var velocity), Is.True);
            Assert.That(velocity.magnitude, Is.EqualTo(4f));
        }

        [Test]
        public void ShouldWaitDistinguishesAFastPendingSwingFromADropAndACompletedSwing()
        {
            var fast = new LateRelease(1f, Vector3.forward * 4f);
            var drop = new LateRelease(1f, Vector3.forward * .1f);
            Assert.That(fast.ShouldWait(1f), Is.True);
            Assert.That(drop.ShouldWait(1f), Is.False);
            Assert.That(fast.ShouldWait(1.25f), Is.False, "wait is measured from release time, not absolute time");
            Assert.That(fast.TryComplete(1.25f, out _), Is.True);
            Assert.That(fast.ShouldWait(1.26f), Is.False);
        }
    }
}
