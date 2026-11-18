using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class HandThrowStopTests
    {
        [SetUp] public void SetUp() => ThrowTuning.Reset();
        [TearDown] public void TearDown() => ThrowTuning.Reset();

        [Test]
        public void LaggedMedianMustNotClassifyForwardApexAsWindup()
        {
            var history = new ThrowHistory();
            var velocities = new[] { Vector3.forward, Vector3.forward * 2f,
                Vector3.forward * 6f, Vector3.forward * 12f,
                new Vector3(1.12f, 0f, 9.08f), new Vector3(-2.25f, 0f, -3.21f),
                new Vector3(2.36f, 0f, .41f), new Vector3(3.92f, 0f, -4.30f),
                new Vector3(-.78f, 0f, -4.76f), new Vector3(-2.81f, 0f, -.96f) };
            for (var i = 0; i < velocities.Length; i++)
                history.Add(new ThrowSample(i / 72f, velocities[i], Vector3.zero, ThrowSources.HandPalm));
            HandReleaseVelocity.Choose(9f / 72f, history, .04f, out var chosen);
            Assert.That(chosen.Linear.z, Is.GreaterThanOrEqualTo(12f * .6f));
        }

        // Synthetic 72 Hz palm paths with both aligned and reversing follow-through.
        [TestCase(12f, 4f, 0f, -1f, 1f, false, false)]
        [TestCase(10f, 2f, 0f, -1f, -2f, false, true)]
        [TestCase(10f, 10f, 0f, -1f, 3f, false, false)]
        [TestCase(13f, .5f, 1f, 2f, 1f, false, false)]
        [TestCase(7f, 2f, -2f, 1f, -1f, true, false)]
        [TestCase(6f, 1.5f, 1f, 1f, 1f, false, false)]
        [TestCase(13f, 2f, 0f, 1f, 2f, false, false)]
        public void ForwardSwingSurvivesStopAndReversal(float speed, float tailSpeed,
            float x, float y, float z, bool turned, bool stops)
        {
            var direction = turned
                ? Quaternion.Euler(0f, -100f, 0f) * Vector3.forward : Vector3.forward;
            var tail = new Vector3(x, y, z).normalized * tailSpeed;
            var history = new ThrowHistory();
            var position = Vector3.zero;
            const float dt = 1f / 72f;
            var previous = position;
            for (var i = 0; i <= 11; i++)
            {
                // Slow -> acceleration -> two near-apex segments -> stop/reversal -> release.
                var v = i < 3 ? direction * 1f : i == 3 ? direction * (speed * .5f)
                    : i <= 5 ? direction * speed : tail;
                if (stops && i == 11) v = Vector3.zero;
                position += v * dt;
                history.Add(new ThrowSample(i * dt, (position - previous) / dt,
                    Vector3.zero, ThrowSources.HandPalm));
                previous = position;
            }
            Assert.That(HandReleaseVelocity.Choose(11 * dt, history, .04f, out var chosen, direction), Is.True);
            Assert.That(Vector3.Dot(chosen.Linear, direction), Is.GreaterThan(0f));
            Assert.That(chosen.Linear.magnitude, Is.GreaterThanOrEqualTo(speed * .6f));
            var launch = PropThrow.Launch(chosen, Vector3.zero);
            Assert.That(launch.magnitude, Is.EqualTo(Mathf.Min(speed * 1.5f, ThrowTuning.TopSpeed)).Within(.05f));
        }
    }
}
