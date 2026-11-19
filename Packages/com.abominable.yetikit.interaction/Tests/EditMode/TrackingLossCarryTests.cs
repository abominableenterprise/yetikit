using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class TrackingLossCarryTests
    {
        [Test]
        public void RecentSwingSurvivesTrackingLossAndEmptyReacquiredHistory()
        {
            var velocity = new HandReleaseVelocity();
            var history = new ThrowHistory();
            var swing = new Vector3(0f, 0f, 6f);
            const float step = 1f / 72f;
            const float smoothing = 0.06f;
            for (var i = 0; i < 8; i++)
                history.Add(new ThrowSample(i * step, swing, Vector3.zero, ThrowSources.HandPalm));

            velocity.TrackingLost(8 * step, history, smoothing);
            velocity.TrackingBack(0.25f);
            var reacquired = new ThrowHistory();
            Assert.That(velocity.Release(0.29f, reacquired, smoothing, out var release), Is.True);
            Assert.That(Vector3.Distance(release.Linear, swing), Is.LessThan(1e-4f));
            Assert.That(release.Source, Is.EqualTo(ThrowSources.HandPalm));
            Assert.That(velocity.Release(0.36f, reacquired, smoothing, out _), Is.False);
        }
    }
}
