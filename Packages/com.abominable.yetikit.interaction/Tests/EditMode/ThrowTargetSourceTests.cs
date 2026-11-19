using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class ThrowTargetSourceTests
    {
        sealed class Source : IThrowTargetSource
        {
            public Source() : this(new Vector3(0.4f, 0f, 5f)) { }
            public Source(Vector3 position) => Targets = new[] { new ThrowTarget(position, Vector3.zero, true) };
            public IReadOnlyList<ThrowTarget> Targets { get; }
        }

        [Test]
        public void ReplacementSurvivesOldHandleDisposal()
        {
            var replacement = new Source();
            using (var first = ThrowTargetSource.Register(new Source()))
            {
                using (ThrowTargetSource.Register(replacement))
                {
                    first.Dispose();
                    Assert.That(ThrowTargetSource.Current, Is.SameAs(replacement));
                }
                Assert.That(ThrowTargetSource.Current, Is.Null);
            }
        }

        [TestCase(false)]
        [TestCase(true)]
        public void ReachableVerticalThrowIsNotBoosted(bool registered)
        {
            const float gravity = 9.81f;
            var velocity = Vector3.up * 8f;
            var target = Vector3.up * 2f;
            using (ThrowTargetSource.Register(new Source(target)))
            {
                bool applied;
                var result = registered
                    ? ThrowAssist.ApplyMoving(Vector3.zero, velocity, gravity, out applied)
                    : ThrowAssist.Apply(Vector3.zero, velocity, new[] { target }, gravity, out applied);
                Assert.That(result, Is.EqualTo(velocity));
                Assert.That(applied, Is.False);
            }
        }

        [Test]
        public void ExplicitTargetsBypassRegisteredSource()
        {
            const float gravity = 9.81f;
            var velocity = ThrowAssist.Aim(new Vector3(0f, 0f, 5f), 10f, gravity) * 10f;
            using (ThrowTargetSource.Register(new Source()))
            {
                ThrowAssist.ApplyMoving(Vector3.zero, velocity, gravity, out var registeredApplied);
                Assert.That(registeredApplied, Is.True);
                var result = ThrowAssist.ApplyMoving(Vector3.zero, velocity, System.Array.Empty<ThrowTarget>(), gravity, out var explicitApplied);
                Assert.That(explicitApplied, Is.False);
                Assert.That(result, Is.EqualTo(velocity));
            }
        }
    }
}
