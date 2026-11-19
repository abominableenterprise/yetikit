using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    /// <summary>Ballistic aim assist against stationary synthetic targets.</summary>
    public class ThrowAssistTests
    {
        const float G = 9.81f;
        const float ProjectileRadius = 0.03f;
        static readonly Vector3 PrimaryTarget = new Vector3(0f, 1.3f, 3f);
        const float TargetRadius = 0.18f, TargetHeight = 0.44f;
        static readonly Vector3 SecondaryTarget = new Vector3(0f, 1.75f, 3f);
        static readonly Vector3 Hand = new Vector3(0.15f, 1.35f, 0f);

        static List<Vector3> Targets => new List<Vector3> { PrimaryTarget, SecondaryTarget };

        /// <summary>Flies the arc (no drag, 1 ms steps) and says whether the projectile touches the primary target capsule.</summary>
        static bool HitsTarget(Vector3 from, Vector3 v)
        {
            var p = from;
            for (var t = 0f; t < 2f; t += 0.001f)
            {
                var axisY = Mathf.Clamp(p.y, PrimaryTarget.y - TargetHeight * 0.5f + TargetRadius, PrimaryTarget.y + TargetHeight * 0.5f - TargetRadius);
                if (Vector3.Distance(p, new Vector3(PrimaryTarget.x, axisY, PrimaryTarget.z)) <= TargetRadius + ProjectileRadius) return true;
                if (p.z > PrimaryTarget.z + 1f || p.y < 0f) return false;
                v += Vector3.down * G * 0.001f;
                p += v * 0.001f;
            }
            return false;
        }

        static Vector3 Off(Vector3 v, float yawDegrees) => Quaternion.AngleAxis(yawDegrees, Vector3.up) * v;

        [Test]
        public void AssistCorrectsASixDegreeMissAtThreeMetres()
        {
            const float speed = 7f; // a soft overhand: a ~4.7 m/s hand × 1.5
            var aimed = ThrowAssist.Aim(PrimaryTarget - Hand, speed, G) * speed;
            Assert.That(HitsTarget(Hand, aimed), Is.True, "the arc itself is right");
            var thrown = Off(aimed, 6f);
            Assert.That(HitsTarget(Hand, thrown), Is.False, "6° off misses the target unassisted");
            var assisted = ThrowAssist.Apply(Hand, thrown, Targets, G, out var applied);
            Assert.That(applied, Is.True);
            Assert.That(Vector3.Angle(assisted, thrown), Is.LessThanOrEqualTo(ThrowAssist.MaxNudge + 1e-3f));
            Assert.That(HitsTarget(Hand, assisted), Is.True, "assisted, it hits the target");
        }

        [Test]
        public void AFlatThrowThatWouldFallShortGetsAtMostFifteenPercent()
        {
            // 7° under the arc that reaches the target at 7 m/s: the 5° nudge alone still drops short, a little speed carries it.
            const float speed = 7f;
            var arc = ThrowAssist.Aim(PrimaryTarget - Hand, speed, G);
            var right = Vector3.Cross(Vector3.up, arc).normalized;
            var thrown = Quaternion.AngleAxis(7f, right) * arc * speed;
            Assert.That(Vector3.Angle(thrown, arc), Is.EqualTo(7f).Within(0.01f));
            Assert.That(HitsTarget(Hand, thrown), Is.False, "falls short unassisted");
            var assisted = ThrowAssist.Apply(Hand, thrown, Targets, G, out var applied);
            Assert.That(applied, Is.True);
            Assert.That(assisted.magnitude, Is.GreaterThan(speed + 0.05f), "sped up: the nudged arc alone falls short");
            Assert.That(assisted.magnitude, Is.LessThanOrEqualTo(thrown.magnitude * ThrowAssist.MaxBoost + 1e-3f));
            Assert.That(assisted.magnitude, Is.GreaterThanOrEqualTo(thrown.magnitude - 1e-3f), "never slower");
            Assert.That(HitsTarget(Hand, assisted), Is.True);
        }

        [Test]
        public void AlreadyLedThrowIsNotNudgedBehindMovingTarget()
        {
            var from = new Vector3(0f, 1.5f, 0f);
            var thrown = new Vector3(0f, G * .5f, 7f);
            var targets = new[] { new ThrowTarget(from + Vector3.forward * 4f, Vector3.forward * 3f, true) };

            var assisted = ThrowAssist.ApplyMoving(from, thrown, targets, G, out _);
            Assert.That(Vector3.Distance(assisted, thrown), Is.LessThan(.001f));
        }

        [Test]
        public void AssistSkipsTargetWithNoHorizontalIntercept()
        {
            var at = Vector3.forward * 4f;
            var thrown = Off(ThrowAssist.Aim(at, 8f, G) * 8f, 4f);
            var targets = new[] { new ThrowTarget(at, Vector3.forward * 9f, true) };

            var assisted = ThrowAssist.ApplyMoving(Vector3.zero, thrown, targets, G, out var applied);
            Assert.That(applied, Is.False);
            Assert.That(assisted, Is.EqualTo(thrown));
        }

        [Test]
        public void AThrowWellOffTargetIsUntouched()
        {
            var thrown = Off(ThrowAssist.Aim(PrimaryTarget - Hand, 7f, G) * 7f, 15f);
            var v = ThrowAssist.Apply(Hand, thrown, Targets, G, out var applied);
            Assert.That(applied, Is.False);
            Assert.That(v, Is.EqualTo(thrown));
        }

        [Test]
        public void ATargetBeyondEightMetresIsNeverAssisted()
        {
            var far = Hand + new Vector3(0f, 0f, ThrowAssist.Range + 0.5f);
            var thrown = Off(ThrowAssist.Aim(far - Hand, 12f, G) * 12f, 4f);
            ThrowAssist.Apply(Hand, thrown, new List<Vector3> { far }, G, out var applied);
            Assert.That(applied, Is.False);
        }

        [Test]
        public void ADropOrAGentlePassIsNeverAssisted()
        {
            var thrown = Off((PrimaryTarget - Hand).normalized, 3f) * (ThrowAssist.MinSpeed - 0.1f);
            ThrowAssist.Apply(Hand, thrown, Targets, G, out var applied);
            Assert.That(applied, Is.False);
            ThrowAssist.Apply(Hand, Off(ThrowAssist.Aim(PrimaryTarget - Hand, 7f, G) * 7f, 3f), null, G, out applied);
            Assert.That(applied, Is.False, "no targets");
        }

        [Test]
        public void TheConstantsAreGentle()
        {
            Assert.That(ThrowAssist.Cone, Is.EqualTo(8f));
            Assert.That(ThrowAssist.MaxNudge, Is.EqualTo(5f));
            Assert.That(ThrowAssist.Range, Is.EqualTo(8f));
            Assert.That(ThrowAssist.MaxBoost, Is.EqualTo(1.15f));
        }
    }
}
