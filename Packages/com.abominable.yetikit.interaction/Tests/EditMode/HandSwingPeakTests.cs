using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class HandSwingPeakTests
    {
        [SetUp] public void SetUp() => ThrowTuning.Reset();
        [TearDown] public void TearDown() => ThrowTuning.Reset();

        static void Add(ThrowHistory history, float time, Vector3 velocity) =>
            history.Add(new ThrowSample(time, velocity, Vector3.zero, ThrowSources.HandPalm));

        // A narrow but supported apex: the per-axis median loses its magnitude when the palm curves.
        static ThrowHistory Swing()
        {
            var history = new ThrowHistory();
            Add(history, 0f, Vector3.forward * 4f);
            Add(history, .01f, Vector3.forward * 7f);
            Add(history, .02f, Vector3.forward * 10f);
            Add(history, .03f, Vector3.forward * 12f);
            Add(history, .04f, new Vector3(6f, 0f, 9f));
            for (var i = 5; i <= 15; i++) Add(history, i * .01f, Vector3.right * 2f);
            return history;
        }

        [Test]
        public void LateReleaseKeepsSupportedSwingPeakDirectionPowerAndCap()
        {
            var history = Swing();
            Assert.That(HandReleaseVelocity.Choose(.15f, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.magnitude, Is.EqualTo(12f).Within(.01f));
            Assert.That(Vector3.Angle(chosen.Linear, Vector3.forward), Is.LessThan(.1f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).magnitude, Is.EqualTo(16f).Within(.01f));
            ThrowTuning.Set(ThrowTuning.TopSpeedId, 30f);
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).magnitude, Is.EqualTo(18f).Within(.01f));
            ThrowTuning.Set(ThrowTuning.PowerId, 2f);
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).magnitude, Is.EqualTo(24f).Within(.01f));
        }

        [TestCase(40f)]
        [TestCase(13f)]
        public void IsolatedTrackingSpikeCannotBecomeSwingPeak(float spike)
        {
            var history = new ThrowHistory();
            for (var i = 0; i <= 20; i++)
                Add(history, i * .01f, Vector3.forward * (i == 10 ? spike : 2f));
            HandReleaseVelocity.Choose(.2f, history, .04f, out var chosen);
            Assert.That(chosen.Linear.magnitude, Is.EqualTo(2f).Within(.01f));
        }

        [Test]
        public void RejectedSpikeBeforeReleaseFlickMustNotCollapseAcceptedFlick()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            for (var i = 0; i <= 12; i++)
                Add(history, i * dt, Vector3.forward * (i == 8 ? 13f : i == 12 ? 4f : 1f));

            Assert.That(HandReleaseVelocity.Choose(12 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(history.RawPeak, Is.EqualTo(13f).Within(.01f), "raw diagnostics retain rejected spikes");
            Assert.That(chosen.Linear.z, Is.EqualTo(4f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(6f).Within(.01f));
        }

        [Test]
        public void RejectedFollowThroughSpikeMustNotCutOffForwardApex()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            for (var i = 0; i <= 14; i++)
            {
                var speed = i < 3 ? 2f : i <= 7 ? 8f : i == 10 ? -13f : -2f;
                Add(history, i * dt, Vector3.forward * speed);
            }

            Assert.That(HandReleaseVelocity.Choose(14 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(history.HandSwingPeak(14 * dt, .04f, out var swing), Is.True);
            Assert.That(swing.Linear.z, Is.EqualTo(8f).Within(.01f));
            Assert.That(chosen.Linear.z, Is.EqualTo(8f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(12f).Within(.01f));
        }

        [Test]
        public void AbruptForwardFlickMustNotExposeSupportedWindup()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { -2f, -5f, -8f, -8f, -8f, -8f, 2f, 11f, 13f, 5f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);
            HandReleaseVelocity.Choose(9 * dt, history, .04f, out var chosen);
            Assert.That(chosen.Linear.z, Is.EqualTo(11f).Within(.01f));
        }

        [Test]
        public void SlowReverseTailMustNotReplaceValidatedForwardFlick()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, 0f, 2f, 11f, 13f, 5f, -1f, -1f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);

            Assert.That(history.Release(8 * dt, out var normal, .04f), Is.True);
            Assert.That(normal.Linear.z, Is.EqualTo(11f).Within(.01f));
            Assert.That(HandReleaseVelocity.Choose(8 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(11f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z,
                Is.EqualTo(ThrowTuning.TopSpeed).Within(.01f), "the forward flick must launch at the hand cap");
        }

        [Test]
        public void SharpReverseTailMustNotReplaceExcludedForwardFlick()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, 0f, 2f, 11f, 13f, 5f, -1f, -4.5f, -6f, -4.5f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);

            Assert.That(history.Release(10 * dt, out var normal, .04f), Is.True);
            Assert.That(normal.Linear.z, Is.EqualTo(11f).Within(.01f));
            Assert.That(HandReleaseVelocity.Choose(10 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(11f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z,
                Is.EqualTo(ThrowTuning.TopSpeed).Within(.01f));
        }

        [Test]
        public void SupportedForwardSwingMustSurviveSlowerReverseFollowThrough()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, 2f, 5f, 9f, 11.8f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);

            Assert.That(history.Release(12 * dt, out var normal, .04f), Is.True);
            Assert.That(normal.Linear.z, Is.EqualTo(10f).Within(.01f));
            Assert.That(HandReleaseVelocity.Choose(12 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(10f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(15f).Within(.01f));
        }

        [Test]
        public void SupportedForwardSwingMustSurviveSettledReverseFollowThrough()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, 2f, 5f, 9f, 11.8f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f, -2f, -1f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);
            Assert.That(HandReleaseVelocity.Choose(14 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(10f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(15f).Within(.01f));
        }

        [Test]
        public void OpposingSwingSelectionWithoutFacingIsInvariantUnderHalfTurn()
        {
            var speeds = new[] { 0f, 0f, 2f, 5f, 9f, 11f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f, -2f, -1f, -1f };
            var original = new ThrowHistory();
            var rotated = new ThrowHistory();
            for (var i = 0; i < speeds.Length; i++)
            {
                Add(original, i / 72f, Vector3.forward * speeds[i]);
                Add(rotated, i / 72f, Vector3.back * speeds[i]);
            }
            Assert.That(HandReleaseVelocity.Choose(15 / 72f, original, .04f, out var first), Is.True);
            Assert.That(HandReleaseVelocity.Choose(15 / 72f, rotated, .04f, out var second), Is.True);
            Assert.That(Vector3.Distance(first.Linear, -second.Linear), Is.LessThan(.01f));
        }

        [Test]
        public void OneFrameLaterSettlingRecoilMustNotReverseForwardThrow()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, 2f, 5f, 9f, 11.8f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f, -2f, -1f, -1f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);
            Assert.That(HandReleaseVelocity.Choose(15 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(10f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(15f).Within(.01f));
        }

        [Test]
        public void GentlerForwardSwingAfterWindupFromRestMustRemainForward()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, -4f, -8f, -10f, -10f, -10f, -6f, -2f, 3f, 6f, 4.5f, 1f, 0f, 0f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);
            Assert.That(HandReleaseVelocity.Choose(14 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(6f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(9f).Within(.01f));
        }

        [Test]
        public void GentlerForwardSwingAfterWindupFromRestMustRemainForwardWhileMoving()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, -4f, -8f, -10f, -10f, -10f, -6f, -2f, 3f, 6f, 4.5f, 1f, 1f, 1f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);
            Assert.That(HandReleaseVelocity.Choose(14 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(6f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(9f).Within(.01f));
        }

        [TestCase(-8f, -11f)]
        [TestCase(-13f, -10f)]
        public void GentlerForwardSwingMustSurviveStrongerOrJitteryWindup(float step, float plateau)
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { 0f, 0f, -4f, step, plateau, plateau, plateau, -6f, -2f, 3f, 6f, 4.5f, 1f, 1f, 1f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);
            Assert.That(HandReleaseVelocity.Choose(14 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(6f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(9f).Within(.01f));
        }

        [Test]
        public void SupportedGentlerForwardSwingMustReplaceExcludedFastWindup()
        {
            const float dt = 1f / 72f;
            var history = new ThrowHistory();
            var speeds = new[] { -10f, -10f, -10f, -6f, -2f, 3f, 6f, 4.5f, 1f, 0f, 0f };
            for (var i = 0; i < speeds.Length; i++) Add(history, i * dt, Vector3.forward * speeds[i]);

            Assert.That(HandReleaseVelocity.Choose(10 * dt, history, .04f, out var chosen), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(6f).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(9f).Within(.01f));
        }

        [Test]
        public void BoundaryRecoilMustNotBecomeWindup()
        {
            AssertFacingSelectedSpeed(new[] { 0f, 0f, 2f, 5f, 9f, 11f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f, -2f, -1f, -1f }, 10f);
        }

        [TestCase(1)]
        [TestCase(2)]
        public void EarlyDeceleratingTossMustBeatBackswing(int tailFrames)
        {
            var speeds = new[] { 0f, 0f, -4f, -8f, -10f, -10f, -10f, -6f, -2f, 3f, 6f, 4.5f, 1f, 1f };
            System.Array.Resize(ref speeds, 12 + tailFrames);
            AssertFacingSelectedSpeed(speeds, 6f);
        }

        [Test]
        public void NeutralTailFrameMustNotRestoreBackswing()
        {
            AssertFacingSelectedSpeed(new[] { 0f, 0f, -4f, -8f, -10f, -10f, -10f, -6f, -2f, 3f, 6f, 4.5f, 1f, 0f, 1f }, 6f);
        }

        [TestCase(0f, 10f)]
        [TestCase(90f, -6f)]
        [TestCase(180f, -6f)]
        public void FacingSelectsButNeverRedirectsSupportedSwing(float headYaw, float expected)
        {
            var speeds = new[] { 0f, 0f, 2f, 5f, 9f, 11f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f, -2f, -1f, -1f };
            var history = new ThrowHistory();
            for (var i = 0; i < speeds.Length; i++) Add(history, i / 72f, Vector3.forward * speeds[i]);
            // Pitch must not affect the decision; 90 degrees is sideways and exercises legacy settling.
            var head = Quaternion.Euler(35f, headYaw, 0f) * Vector3.forward;
            HandReleaseVelocity.Choose(15 / 72f, history, .04f, out var chosen, head);
            Assert.That(chosen.Linear.z, Is.EqualTo(expected).Within(.01f));
            Assert.That(chosen.Linear.x, Is.Zero.Within(.001f));
            Assert.That(chosen.Linear.y, Is.Zero.Within(.001f));
        }

        [Test]
        public void NearVerticalThrowMustNotUseTinyHorizontalRecoilAsFacingEvidence()
        {
            var speeds = new[] { 0f, 0f, 2f, 5f, 9f, 11.8f, 10f, 9f, 3f, -1f, -4.5f, -6f, -4.5f };
            var direction = new Vector3(0f, 1f, -.01f).normalized;
            var history = new ThrowHistory();
            for (var i = 0; i < speeds.Length; i++) Add(history, i / 72f, direction * speeds[i]);
            HandReleaseVelocity.Choose(12 / 72f, history, .04f, out var chosen, Vector3.forward);
            Assert.That(Vector3.Dot(chosen.Linear, direction), Is.EqualTo(10f).Within(.01f));
            Assert.That(Vector3.Dot(PropThrow.Launch(chosen, Vector3.zero), direction), Is.EqualTo(15f).Within(.01f));
        }

        static void AssertFacingSelectedSpeed(float[] speeds, float expected)
        {
            var history = new ThrowHistory();
            for (var i = 0; i < speeds.Length; i++) Add(history, i / 72f, Vector3.forward * speeds[i]);
            Assert.That(HandReleaseVelocity.Choose((speeds.Length - 1) / 72f, history, .04f, out var chosen, Vector3.forward), Is.True);
            Assert.That(chosen.Linear.z, Is.EqualTo(expected).Within(.01f));
            Assert.That(PropThrow.Launch(chosen, Vector3.zero).z, Is.EqualTo(expected * 1.5f).Within(.01f));
        }

        [Test]
        public void ForgivenessStillControlsTheHandLookback()
        {
            ThrowTuning.Set(ThrowTuning.ForgivenessId, .05f);
            HandReleaseVelocity.Choose(.15f, Swing(), .04f, out var chosen);
            Assert.That(chosen.Linear.magnitude, Is.EqualTo(2f).Within(.01f));
        }

        [Test]
        public void ControllerSelectionIsUnchanged()
        {
            var history = Swing();
            history.Release(.15f, out var before);
            HandReleaseVelocity.Choose(.15f, history, .04f, out _);
            history.Release(.15f, out var after);
            Assert.That(after.Linear, Is.EqualTo(before.Linear));
            Assert.That(after.Angular, Is.EqualTo(before.Angular));
            Assert.That(after.Time, Is.EqualTo(before.Time));
        }
    }
}
