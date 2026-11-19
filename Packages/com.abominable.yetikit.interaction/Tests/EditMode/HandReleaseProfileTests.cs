using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    /// <summary>Shared release matrix: genuine flicks and tracking returns use the same sampler rules.</summary>
    public class HandReleaseProfileTests
    {
        const float Dt = 1f / 72f;
        const float Smoothing = 0.04f;

        public sealed class Profile
        {
            public string Name;
            public float[] Speeds;
            public int Pause;
            public float Gap = Dt;
            public float Expected;
            public bool DiscardedSnap;
            public override string ToString() => Name;
        }

        public static IEnumerable<Profile> Profiles()
        {
            yield return new Profile { Name = "Still then flick", Speeds = new[] { 0f }, Expected = 9f };
            yield return new Profile { Name = "Stopped wind-up one frame", Speeds = new[] { -3f, -3f, -3f }, Pause = 1, Expected = 9f };
            yield return new Profile { Name = "Stopped wind-up two frames", Speeds = new[] { -3f, -3f, -3f }, Pause = 2, Expected = 9f };
            yield return new Profile { Name = "Accepted snap immediate return", Speeds = new[] { 12.96f }, Expected = 0f };
            yield return new Profile { Name = "Accepted snap paused return", Speeds = new[] { 12.96f }, Pause = 1, Expected = 0f };
            yield return new Profile { Name = "Slow motion then spike paused one-frame return", Speeds = new[] { 0.6f, 0.6f, 12.96f }, Pause = 1, Expected = 0.9f };
            yield return new Profile { Name = "Slow motion then spike paused two-frame return", Speeds = new[] { 0.6f, 0.6f, 12.96f }, Pause = 1, Gap = 2 * Dt, Expected = 0.9f };
            yield return new Profile { Name = "Accepted snap dropped-frame return", Speeds = new[] { 12.96f }, Gap = 2 * Dt, Expected = 0f };
            yield return new Profile { Name = "Accepted snap four-frame return", Speeds = new[] { 12.96f }, Gap = 4 * Dt, Expected = 0f };
            yield return new Profile { Name = "Accepted snap 160ms return", Speeds = new[] { 12.96f }, Gap = 0.16f, Expected = 0f };
            yield return new Profile { Name = "Discarded snap delayed return", Speeds = new float[0], DiscardedSnap = true, Pause = 2, Gap = 2 * Dt, Expected = 0f };
            yield return new Profile { Name = "Discarded snap long still return", Speeds = new float[0], DiscardedSnap = true, Pause = 10, Gap = 2 * Dt, Expected = 0f };
            yield return new Profile { Name = "Dropped-frame flick", Speeds = new[] { 0f }, Gap = 2 * Dt, Expected = 9f };
            yield return new Profile { Name = "Hitched flick", Speeds = new[] { 0f }, Gap = 4 * Dt, Expected = 9f };
        }

        [TestCaseSource(nameof(Profiles))]
        public void ReleaseProfilesKeepFlicksAndRejectSnapReturns(Profile p)
        {
            var h = new ThrowHistory();
            var t = 0f;
            for (var f = 0; f < 12; f++, t += Dt) Add(h, t, 0f);
            foreach (var speed in p.Speeds) { Add(h, t, speed); t += Dt; }
            if (p.DiscardedSnap) h.Discontinuity();
            for (var f = 0; f < p.Pause; f++, t += Dt) Add(h, t, 0f);
            t += p.Gap - Dt;
            var returning = p.DiscardedSnap || (p.Speeds.Length > 0 && p.Speeds[p.Speeds.Length - 1] > 10f);
            Add(h, t, returning ? -(p.DiscardedSnap ? 0.25f : 0.18f) / p.Gap : 6f);
            Assert.That(HandReleaseVelocity.Choose(t, h, Smoothing, out var release), Is.True);
            var launch = PropThrow.Launch(release, Vector3.zero);
            Assert.That(launch.z, Is.EqualTo(p.Expected).Within(0.01f));
            Assert.That(launch.magnitude, Is.EqualTo(Mathf.Abs(p.Expected)).Within(0.01f));
        }

        [Test]
        public void TwoFramesAfterDiscontinuityCannotBorrowSmoothingSupport()
        {
            var h = new ThrowHistory();
            for (var frame = 0; frame < 4; frame++) Add(h, frame * Dt, 0f);
            h.Discontinuity();
            Add(h, 4 * Dt, -9f);
            Add(h, 5 * Dt, -9f);

            Assert.That(HandReleaseVelocity.Choose(5 * Dt, h, Smoothing, out var release), Is.True);
            Assert.That(release.Linear, Is.EqualTo(Vector3.zero));
        }

        [Test]
        public void DiscontinuityKeepsAnAlreadySmoothedPeak()
        {
            var h = new ThrowHistory();
            for (var frame = 0; frame < 4; frame++) Add(h, frame * Dt, 8f);
            h.Discontinuity();
            Add(h, 4 * Dt, 0f);
            Add(h, 5 * Dt, 0f);

            Assert.That(h.Release(5 * Dt, out var release, Smoothing), Is.True);
            Assert.That(release.Linear.z, Is.EqualTo(8f));
        }

        [TestCase(12.96f, 0.6f, 0.6f, false)]
        [TestCase(0.6f, 12.96f, 0.6f, false)]
        [TestCase(0.6f, 0.6f, 12.96f, false)]
        [TestCase(3f, 6f, 6f, true)]
        [TestCase(6f, 3f, 3f, true)]
        [TestCase(8f, 8f, 8f, true)]
        public void ADisplacedBaselineNeedsIndependentSpeedSupport(float first, float second, float third, bool established)
        {
            var h = new ThrowHistory();
            Add(h, 0f, first);
            Add(h, Dt, second);
            Add(h, 2 * Dt, third);
            Assert.That(h.LatestMotionEstablished, Is.EqualTo(established));
        }

        static void Add(ThrowHistory h, float t, float speed) =>
            h.Add(new ThrowSample(t, Vector3.forward * speed, Vector3.zero, ThrowSources.HandPalm));
    }
}
