using System;
using System.Globalization;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class ThrowTuningTests
    {
        [SetUp] public void SetUp() => ThrowTuning.Reset();
        [TearDown] public void TearDown() => ThrowTuning.Reset();

        [Test]
        public void DefaultsAreExactAndSparseJsonIsEmpty()
        {
            Assert.That(ThrowTuning.Power, Is.EqualTo(1.5f));
            Assert.That(ThrowTuning.TopSpeed, Is.EqualTo(16f));
            Assert.That(ThrowTuning.Forgiveness, Is.EqualTo(0.15f));
            Assert.That(ThrowTuning.AimHelp, Is.EqualTo(1f));
            Assert.That(ThrowTuning.IsDefault, Is.True);
            Assert.That(ThrowTuning.Json(true), Is.EqualTo("{}"));
            Assert.That(ThrowTuning.Json(), Is.EqualTo("{\"power\":1.5,\"top_speed\":16,\"forgiveness\":0.15,\"aim_help\":1}"));
        }

        [TestCase("power", -1f, 0.8f)]
        [TestCase("power", 100f, 2.5f)]
        [TestCase("power", 1.53f, 1.53f)]
        [TestCase("top_speed", 0f, 8f)]
        [TestCase("top_speed", 99f, 30f)]
        [TestCase("top_speed", 16.8f, 16.8f)]
        [TestCase("forgiveness", 0f, 0.05f)]
        [TestCase("forgiveness", 1f, 0.30f)]
        [TestCase("forgiveness", 0.166f, 0.166f)]
        [TestCase("aim_help", -1f, 0f)]
        [TestCase("aim_help", 3f, 2f)]
        [TestCase("aim_help", 1.16f, 1.16f)]
        public void ValuesAreClampedWithoutRounding(string id, float input, float expected)
        {
            ThrowTuning.Set(id, input);
            Assert.That(ThrowTuning.Json(), Does.Contain("\"" + id + "\":" + expected.ToString("R", CultureInfo.InvariantCulture)));
        }

        [Test]
        public void OnlyRealChangesNotifyAndResetRestoresDefaults()
        {
            var changes = 0;
            Action changed = () => changes++;
            ThrowTuning.Changed += changed;
            try
            {
                ThrowTuning.Set("power", 1.5f);
                ThrowTuning.Set("unknown", 2f);
                ThrowTuning.Set(null, 2f);
                ThrowTuning.Set("power", float.NaN);
                ThrowTuning.Set("power", float.PositiveInfinity);
                Assert.That(changes, Is.Zero);
                ThrowTuning.Set("power", 2f);
                ThrowTuning.Set("power", 2f);
                Assert.That(ThrowTuning.IsDefault, Is.False);
                Assert.That(ThrowTuning.Json(true), Is.EqualTo("{\"power\":2}"));
                ThrowTuning.Reset();
                ThrowTuning.Reset();
                Assert.That(changes, Is.EqualTo(2));
                Assert.That(ThrowTuning.IsDefault, Is.True);
            }
            finally { ThrowTuning.Changed -= changed; }
        }

        [Test]
        public void PowerChangesLaunchAndHandCapIsTunableButHardBounded()
        {
            var input = Vector3.forward * 4f;
            Assert.That(PropThrow.Linear(input), Is.EqualTo(input * 1.5f));
            ThrowTuning.Set("power", 2f);
            Assert.That(PropThrow.Linear(input), Is.EqualTo(input * 2f));
            ThrowTuning.Set("top_speed", 24f);
            var hand = new ThrowSample(0f, Vector3.forward * 100f, Vector3.zero, ThrowSources.HandPalm);
            Assert.That(PropThrow.Launch(hand, Vector3.zero).magnitude, Is.EqualTo(24f));
            ThrowTuning.Set("top_speed", 100f);
            Assert.That(PropThrow.Launch(hand, Vector3.zero).magnitude, Is.EqualTo(30f));
        }

        [TestCase(0f)]
        [TestCase(0.1f)]
        public void MaximumForgivenessRetainsBoundaryPeakAndSmoothingAt120Hz(float smoothing)
        {
            const int sampleRate = 120, releaseFrame = 120, peakFrame = 84;
            var history = new ThrowHistory();
            ThrowTuning.Set(ThrowTuning.ForgivenessId, ThrowTuning.MaxForgiveness);
            // Peak is exactly .30 s old. Its entire .10 s smoothing lookback is fast,
            // but everything after it is slow (no late-speed extension can rescue it).
            for (int frame = 0; frame <= releaseFrame; frame++)
            {
                var speed = frame >= peakFrame - 12 && frame <= peakFrame ? 8f : 1f;
                history.Add(new ThrowSample((float)frame / sampleRate, Vector3.forward * speed, Vector3.zero));
            }
            Assert.That(history.Release(1f, out var peak, smoothing), Is.True);
            Assert.That(peak.Linear.magnitude, Is.EqualTo(8f).Within(.0001f));
            ThrowTuning.Reset();
            history.Release(1f, out var normal, smoothing);
            Assert.That(normal.Linear.magnitude, Is.EqualTo(1f).Within(.0001f),
                "extra retained history must not extend the default release window");
        }

        [Test]
        public void ForgivenessChangesTheSlowReleaseWindow()
        {
            var history = new ThrowHistory();
            history.Add(new ThrowSample(0f, Vector3.forward * 2f, Vector3.zero));
            history.Add(new ThrowSample(0.04f, Vector3.forward, Vector3.zero));
            history.Add(new ThrowSample(0.08f, Vector3.forward, Vector3.zero));
            history.Release(0.08f, out var normal);
            ThrowTuning.Set("forgiveness", 0.05f);
            history.Release(0.08f, out var shortWindow);
            Assert.That(normal.Linear.magnitude, Is.EqualTo(2f));
            Assert.That(shortWindow.Linear.magnitude, Is.EqualTo(1f));
        }

        [Test]
        public void AssistZeroIsExactPassthroughAndOneRetainsOriginalNudge()
        {
            const float gravity = 9.81f, speed = 7f;
            var target = new Vector3(0f, 0f, 3f);
            var aimed = ThrowAssist.Aim(target, speed, gravity) * speed;
            var thrown = Quaternion.AngleAxis(6f, Vector3.up) * aimed;
            var targets = new[] { target };
            var normal = ThrowAssist.Apply(Vector3.zero, thrown, targets, gravity, out var applied);
            Assert.That(applied, Is.True);
            var originalAim = ThrowAssist.Aim(target, thrown.magnitude, gravity);
            var turned = Vector3.RotateTowards(thrown / thrown.magnitude, originalAim, 5f * Mathf.Deg2Rad, 0f);
            var needed = ThrowAssist.SpeedToReach(target, turned, gravity);
            var expected = turned * (needed > thrown.magnitude ? Mathf.Min(needed, thrown.magnitude * 1.15f) : thrown.magnitude);
            Assert.That(normal, Is.EqualTo(expected));
            ThrowTuning.Set("aim_help", 0f);
            Assert.That(ThrowAssist.Apply(Vector3.zero, thrown, targets, gravity, out applied), Is.EqualTo(thrown));
            Assert.That(applied, Is.False);
            ThrowTuning.Set("aim_help", 1f);
            Assert.That(ThrowAssist.Apply(Vector3.zero, thrown, targets, gravity, out applied), Is.EqualTo(normal));
        }
    }
}
