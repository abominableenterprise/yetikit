using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    /// <summary>The throw's pure logic: the release sample, the tuning and the held-prop layer.</summary>
    public class ThrowRulesTests
    {
        const float Dt = 1f / 72f;

        static ThrowHistory Swing(params float[] speeds)
        {
            var h = new ThrowHistory();
            for (var i = 0; i < speeds.Length; i++) h.Add(new ThrowSample(i * Dt, Vector3.forward * speeds[i], Vector3.up * speeds[i]));
            return h;
        }

        [Test]
        public void ReleaseUsesThePeakOfTheLastFewFramesNotTheLastFrame()
        {
            // Wind-up, peak at 8 m/s, then the wrist slows as the fingers open.
            var h = Swing(1f, 3f, 6f, 8f, 7f, 5f, 3f);
            Assert.That(h.Release(6 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f), "the peak, not the 3 m/s last frame");
            Assert.That(s.Angular.magnitude, Is.EqualTo(8f), "spin from the same frame");
        }

        [Test]
        public void TheWindowIsTheLastPointFifteenSeconds()
        {
            // 72 Hz: 0.15 s is 10.8 frames back. The 2 m/s frame 11 back (slow: no late-release reach) ends the window,
            // so the 9 m/s 12 back is out; the 8 m/s one 10 back is in.
            var h = Swing(9f, 2f, 8f, 1f, 1f, 1f, 1f, 1f, 1f, 1f, 1f, 1f, 2f);
            Assert.That(h.Release(12 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f), "8 m/s is 0.139 s before the release, 9 m/s 0.167 s");
            Assert.That(ThrowHistory.PeakWindow, Is.EqualTo(0.15f));
            Assert.That(h.Release(12 * Dt + 0.5f, out _), Is.False, "nothing recent: no throw velocity");
        }

        [Test]
        public void ALateGripReleaseReachesBackAQuarterSecondWhileTheHandIsStillThrowing()
        {
            // Place the peak 17 frames (0.236 s) back, with the hand still moving at least 3 m/s.
            var late = Swing(1f, 9f, 8f, 7.5f, 7f, 6.5f, 6f, 5.5f, 5f, 4.5f, 4f, 4f, 3.5f, 3.5f, 3.5f, 3f, 3f, 3f, 3f);
            Assert.That(late.Release(18 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(9f), "the 9 m/s peak 0.236 s before the late release");
            Assert.That(ThrowHistory.LateWindow, Is.EqualTo(0.25f));
            // A slow lift (1.3 m/s) 0.15+ s before a gentle set-down is no throw.
            var lift = Swing(1.3f, 1.3f, 1.3f, 1.3f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f, 0.2f);
            Assert.That(lift.Release(14 * Dt, out var d), Is.True);
            Assert.That(d.Linear.magnitude, Is.EqualTo(0.2f), "the lift is out of the window: a drop");
        }

        [Test]
        public void ThePeakFramesAtNinetyHertzStillReachBackPastTheGripOpening()
        {
            // At 90 Hz: the hand peaks, then the grip takes 8 frames (89 ms) to open while the wrist slows.
            // The old window (5 frames) only saw the slowing frames; the throw came out at half speed.
            const float dt90 = 1f / 90f;
            var h = new ThrowHistory();
            var speeds = new[] { 2f, 5f, 8f, 8f, 7f, 6f, 5f, 4f, 3f, 3f, 2f, 2f };
            for (var i = 0; i < speeds.Length; i++) h.Add(new ThrowSample(i * dt90, Vector3.forward * speeds[i], Vector3.zero));
            Assert.That(h.Release((speeds.Length - 1) * dt90, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f), "the peak, nine frames before the grip let go");
        }

        [Test]
        public void TheDirectionIsTheAverageOfTheFastestFrames()
        {
            // One noisy frame at the peak points 30° up; the frames either side point straight ahead.
            var h = new ThrowHistory();
            var up30 = Quaternion.AngleAxis(-30f, Vector3.right) * Vector3.forward;
            h.Add(new ThrowSample(0f, Vector3.forward * 7.5f, Vector3.zero));
            h.Add(new ThrowSample(Dt, up30 * 8f, Vector3.zero));
            h.Add(new ThrowSample(2 * Dt, Vector3.forward * 7.5f, Vector3.zero));
            h.Add(new ThrowSample(3 * Dt, Vector3.forward * 2f, Vector3.zero));
            Assert.That(h.Release(3 * Dt, out var s), Is.True);
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f).Within(1e-4f), "the peak speed");
            Assert.That(Vector3.Angle(s.Linear, Vector3.forward), Is.LessThan(11f), "aimed by the top three frames, not the one noisy frame");
        }

        [Test]
        public void AHitchBeforeTheReleaseStillThrows()
        {
            // The last frame took 0.12 s (a hitch): the release comes 0.12 s after the newest sample.
            var h = Swing(1f, 4f, 8f);
            Assert.That(h.Release(2 * Dt + 0.12f, out var s), Is.True, "a hitch is not 'nothing recent'");
            Assert.That(s.Linear.magnitude, Is.EqualTo(8f));
        }

        [Test]
        public void TheSampleRemembersWhereItsVelocityCameFrom()
        {
            const string trackedSource = "tracked-linear";
            var h = new ThrowHistory();
            h.Add(new ThrowSample(0f, Vector3.forward * 3f, Vector3.zero, "frame-delta"));
            h.Add(new ThrowSample(Dt, Vector3.forward * 8f, Vector3.zero, trackedSource));
            Assert.That(h.Release(Dt, out var s), Is.True);
            Assert.That(s.Source, Is.EqualTo(trackedSource));
        }

        [Test]
        public void ThrowTuningIsStrongButPlausible()
        {
            Assert.That(PropThrow.VelocityScale, Is.EqualTo(1.5f));
            Assert.That(PropThrow.AngularScale, Is.EqualTo(1f));
            Assert.That(PropThrow.Linear(Vector3.forward * 7f).magnitude, Is.EqualTo(10.5f).Within(1e-4f));
            Assert.That(PropThrow.Linear(Vector3.forward * 100f).magnitude, Is.EqualTo(PropThrow.MaxSpeed), "tracking glitches are capped");
            Assert.That(PropThrow.LinearDamping, Is.InRange(0f, 0.1f), "drag light enough to carry");
            Assert.That(PropThrow.AngularDamping, Is.InRange(0.05f, 0.5f));
        }

        [Test]
        public void AHeldPropUsesTheHeldLayerThroughTheReleaseGracePeriod()
        {
            var layer = new HeldLayer(0, 7);
            Assert.That(layer.Layer(0f), Is.EqualTo(0));
            layer.Grab();
            Assert.That(layer.Layer(5f), Is.EqualTo(7), "held");
            layer.Release(10f);
            Assert.That(layer.Layer(10f + HeldLayer.Grace * 0.5f), Is.EqualTo(7), "just thrown");
            Assert.That(layer.Layer(10f + HeldLayer.Grace + 0.01f), Is.EqualTo(0), "back to normal");
            Assert.That(HeldLayer.Grace, Is.InRange(0.1f, 1f));
        }
    }
}
