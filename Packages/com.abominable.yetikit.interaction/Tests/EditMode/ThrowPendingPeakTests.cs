using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    /// <summary>Classifying a pending stretch must preserve its fastest frame.</summary>
    public class ThrowPendingPeakTests
    {
        const float Dt = 1f / 72f;

        static Vector3 Upward(float degrees) =>
            new Vector3(0f, Mathf.Sin(degrees * Mathf.Deg2Rad), Mathf.Cos(degrees * Mathf.Deg2Rad));

        static ThrowHistory History(params Vector3[] velocities)
        {
            var h = new ThrowHistory();
            for (var i = 0; i < velocities.Length; i++)
                h.Add(new ThrowSample(i * Dt, velocities[i], Vector3.up * (i + 1), "frame-" + i));
            return h;
        }

        [Test]
        public void ASlowerFrameClassifyingATurnPromotesThePendingPeak()
        {
            var up40 = Upward(40f);
            var up60 = Upward(60f);
            var h = History(up40 * 6f, up60 * 8f, up60 * 4f,
                Vector3.down * 4.5f, Vector3.down * 4.5f, Vector3.down * 4.5f);
            // Scanning backward: 4 and 8 m/s at 60° stay pending (150° from down, ratio > 0.5).
            // The older 6 m/s frame at 40° classifies the turn (130°), but is not its peak.
            Assert.That(h.Release(5 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f).Within(1e-4f), "keep the pending 8 m/s, not the classifying 6 m/s");
            Assert.That(s.Time, Is.EqualTo(Dt), "the pending peak's timestamp");
            Assert.That(s.Angular, Is.EqualTo(Vector3.up * 2f), "spin from the pending peak");
            Assert.That(s.Source, Is.EqualTo("frame-1"), "source from the pending peak");
            Assert.That(h.RawPeak, Is.EqualTo(8f).Within(1e-4f));
            var expectedAim = (up40 * 6f + up60 * 12f).normalized;
            Assert.That(Vector3.Angle(s.Linear, expectedAim), Is.LessThan(0.1f), "the forward/upward top-three aim, not down");
            Assert.That(PropThrow.Linear(s.Linear).magnitude, Is.EqualTo(12f).Within(1e-3f), "12 m/s after gain, not 9");
        }

        [Test]
        public void APromotedPendingPeakStillExcludesAnEarlierFasterWindUp()
        {
            var up40 = Upward(40f);
            var up60 = Upward(60f);
            var h = History(-up60 * 10f, up40 * 6f, up60 * 8f, up60 * 4f,
                Vector3.down * 4.5f, Vector3.down * 4.5f, Vector3.down * 4.5f);
            Assert.That(h.Release(6 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f).Within(1e-4f), "the throw, not the 10 m/s wind-up");
            Assert.That(s.Time, Is.EqualTo(2 * Dt));
            Assert.That(s.Angular, Is.EqualTo(Vector3.up * 3f));
            Assert.That(s.Source, Is.EqualTo("frame-2"));
            Assert.That(h.RawPeak, Is.EqualTo(8f).Within(1e-4f), "the wind-up is outside the selected window");
            Assert.That(Vector3.Angle(s.Linear, up40 * 6f + up60 * 12f), Is.LessThan(0.1f));
        }

        [TestCase(145f)]
        [TestCase(149f)]
        public void APendingPeakKeepsTheClassifyingDirectionForTheNextReversal(float windUpAngle)
        {
            var up40 = Upward(40f);
            var up60 = Upward(60f);
            var h = History(Upward(windUpAngle) * 10f, up40 * 6f, up60 * 8f, up60 * 4f,
                Vector3.down * 4.5f, Vector3.down * 4.5f, Vector3.down * 4.5f);
            // The wind-up reverses against the 40-degree classifier, not the retained 60-degree peak.
            Assert.That(h.Release(6 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f).Within(1e-4f));
            Assert.That(s.Time, Is.EqualTo(2 * Dt));
            Assert.That(s.Angular, Is.EqualTo(Vector3.up * 3f));
            Assert.That(s.Source, Is.EqualTo("frame-2"));
            Assert.That(h.RawPeak, Is.EqualTo(8f).Within(1e-4f), "exclude the earlier wind-up");
            Assert.That(Vector3.Angle(s.Linear, up40 * 6f + up60 * 12f), Is.LessThan(0.1f));
        }

        [Test]
        public void ACurvingSwingAdvancesTheClassifierWhenAFasterFrameReplacesThePeak()
        {
            var up120 = Upward(120f);
            var h = History(up120 * 10f, Upward(60f) * 8f, Upward(20f) * 6f, Vector3.down * 4.5f);
            // Backward scan promotes 20°, then replaces it with 60°. The 120° peak is a turn from
            // 60°, not a second reversal against the stale 20° classifier.
            Assert.That(h.Release(3 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(10f).Within(1e-4f));
            var expectedAim = (up120 * 10f + Upward(60f) * 8f).normalized;
            Assert.That(Vector3.Angle(s.Linear, expectedAim), Is.LessThan(0.1f), "aim around the true peak, using the unchanged 60-degree cone");
            Assert.That(s.Time, Is.Zero);
            Assert.That(s.Angular, Is.EqualTo(Vector3.up));
            Assert.That(s.Source, Is.EqualTo("frame-0"));
            Assert.That(h.RawPeak, Is.EqualTo(10f).Within(1e-4f));
            Assert.That(PropThrow.Linear(s.Linear).magnitude, Is.EqualTo(15f).Within(1e-3f));
        }

        [TestCase(9f)]
        [TestCase(12f)]
        public void AFasterPendingWindUpWithoutFollowThroughEvidenceIsNotPromoted(float windUpSpeed)
        {
            var h = History(Vector3.back * windUpSpeed, Vector3.back * 6f, Vector3.back * 2f,
                Vector3.forward * 3f, Vector3.forward * 8f, Vector3.forward * 6f, Vector3.forward * 2f);
            // The backward stretch becomes faster than the forward throw but never classifies as its throw:
            // a straight reversal with 8/9 or 8/12 speed ratio must still end the window.
            Assert.That(h.Release(6 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f).Within(1e-4f));
            Assert.That(Vector3.Angle(s.Linear, Vector3.forward), Is.LessThan(0.1f), "never launch backward");
            Assert.That(s.Time, Is.EqualTo(4 * Dt));
            Assert.That(h.RawPeak, Is.EqualTo(8f).Within(1e-4f));
        }
    }
}
