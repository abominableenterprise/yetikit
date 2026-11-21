using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Hands.Tests
{
    public class AngularOneEuroTests
    {
        const float FrameSeconds = 1f / 72f;
        const int AcceptanceFrames = 21; // Less than 0.3 seconds at 72 Hz.

        [Test]
        public void DefaultsFavorSmallDeliberateAdjustments()
        {
            Assert.That(AngularOneEuro.TremorDegrees, Is.EqualTo(0.3f));
            Assert.That(AngularOneEuro.SustainedOffsetSeconds, Is.EqualTo(0.05f));
            Assert.That(AngularOneEuro.MinCutoffHz, Is.EqualTo(3f));
            Assert.That(AngularOneEuro.Beta, Is.EqualTo(4f));
        }

        [TestCase(72)]
        [TestCase(90)]
        public void SustainedOffsetStartsFollowingAfterFiftyMilliseconds(int rate)
        {
            var dt = 1f / rate;
            var filter = new AngularOneEuro();
            filter.Reset(0f);
            filter.Step(0.2f, dt); // Establish an envelope that initially rejects 0.4 degrees.
            for (var frame = 1; frame * dt < 0.05f; frame++)
                Assert.That(filter.Step(0.4f, dt), Is.EqualTo(0f));
            Assert.That(filter.Step(0.4f, dt), Is.GreaterThan(0f));
        }

        [TestCase(0.3f)]
        [TestCase(-0.3f)]
        public void TremorAtNewThresholdRemainsRejected(float firstNoise)
        {
            var filter = new AngularOneEuro();
            filter.Reset(0f);
            for (var frame = 0; frame < 144; frame++)
                Assert.That(filter.Step(frame % 2 == 0 ? firstNoise : -firstNoise, FrameSeconds),
                    Is.EqualTo(0f));
        }

        [TestCase(0.4f)]
        [TestCase(-0.4f)]
        public void SmallDeliberateStepRespondsImmediatelyWithNewCutoff(float offset)
        {
            var filter = new AngularOneEuro();
            filter.Reset(0f);
            var derivativeAlpha = 1f / (1f + 1f / (2f * Mathf.PI * FrameSeconds));
            var derivative = offset / FrameSeconds * derivativeAlpha;
            var cutoff = 3f + 4f * Mathf.Abs(derivative);
            var alpha = 1f / (1f + 1f / (2f * Mathf.PI * cutoff * FrameSeconds));
            Assert.That(filter.Step(offset, FrameSeconds), Is.EqualTo(offset * alpha).Within(0.00001f));
        }

        [Test, Combinatorial]
        public void SustainedSmallOffsetEscapesRejectedEnvelope(
            [Values(0f, 179f, -179f)] float start,
            [Values(0.4f, 0.5f, 0.59f, -0.4f, -0.5f, -0.59f)] float offset,
            [Values(0.01f, 0.2f)] float rejectedStep)
        {
            var filter = new AngularOneEuro();
            filter.Reset(start);
            filter.Step(start + Mathf.Sign(offset) * rejectedStep, FrameSeconds);
            for (var frame = 0; frame < AcceptanceFrames; frame++)
                filter.Step(Mathf.Repeat(start + offset + 180f, 360f) - 180f, FrameSeconds);
            Assert.That(Mathf.Abs(Mathf.DeltaAngle(filter.Value, start + offset)), Is.LessThan(0.05f));
        }

        [TestCase(179f, -179f, 181f)]
        [TestCase(-179f, 179f, -181f)]
        public void FollowingAcrossTheSeamUsesTheShortestArc(float start, float sample, float unwrapped)
        {
            var filter = new AngularOneEuro();
            filter.Reset(start);
            var first = filter.Step(sample, FrameSeconds);
            Assert.That(first, Is.InRange(Mathf.Min(start, unwrapped), Mathf.Max(start, unwrapped)));
            for (var frame = 0; frame < AcceptanceFrames; frame++) filter.Step(sample, FrameSeconds);
            Assert.That(filter.Value, Is.EqualTo(unwrapped).Within(0.05f));
        }

        [Test]
        public void LongSampleGapReseedsToTheAcceptedAngle()
        {
            var filter = new AngularOneEuro();
            filter.Reset(179f);
            filter.Step(179.2f, FrameSeconds);
            Assert.That(filter.Step(-179f, AngularOneEuro.ResetGapSeconds), Is.EqualTo(181f));
            Assert.That(filter.Step(-179.2f, AngularOneEuro.ResetGapSeconds), Is.EqualTo(181f), "tremor is not accepted");
        }

        [TestCase(2f, 0f)]
        [TestCase(2f, -1f)]
        [TestCase(2f, float.PositiveInfinity)]
        [TestCase(2f, float.NaN)]
        [TestCase(float.NaN, FrameSeconds)]
        [TestCase(float.PositiveInfinity, FrameSeconds)]
        public void InvalidSampleDoesNotChangeTheFilter(float angle, float dt)
        {
            var filter = new AngularOneEuro();
            filter.Reset(1f);
            Assert.That(filter.Step(angle, dt), Is.EqualTo(1f));
            Assert.That(filter.Step(1f, FrameSeconds), Is.EqualTo(1f));
        }
    }
}
