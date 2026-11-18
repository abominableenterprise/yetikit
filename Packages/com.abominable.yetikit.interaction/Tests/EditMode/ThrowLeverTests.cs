using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    /// <summary>The throw at the held point (v + ω × r) and where the hand holds a prop's centre of mass.</summary>
    public class ThrowLeverTests
    {
        [Test]
        public void AWristFlickAddsTheSpinTimesTheLever()
        {
            // Hand forward at 7 m/s, wrist pitching forward at 8 rad/s about +X, the prop 15 cm above the controller.
            var v = PropThrow.Linear(Vector3.forward * 7f, Vector3.right * 8f, Vector3.up * 0.15f);
            Assert.That(v.z, Is.EqualTo((7f + 8f * 0.15f) * PropThrow.VelocityScale).Within(1e-4f), "ω × r = 1.2 m/s forward");
            Assert.That(v.y, Is.EqualTo(0f).Within(1e-4f));
        }

        [Test]
        public void APropHeldOutInFrontIsNotSlowedOrBentByTheWrist()
        {
            // Overhand: hand 8 m/s forward and 25° up, wrist pitching forward (about the hand's left-right axis) at
            // 8 rad/s, the prop's centre 20 cm out in front of the controller. ω × r points down and back.
            var dir = Quaternion.AngleAxis(-25f, Vector3.right) * Vector3.forward;
            var omega = Vector3.right * 8f;
            var lever = dir * 0.2f;
            Assert.That(Vector3.Cross(omega, lever).y, Is.LessThan(-1f), "the raw ω × r points 1.5 m/s down");
            var v = PropThrow.Linear(dir * 8f, omega, lever);
            Assert.That(v.magnitude, Is.GreaterThanOrEqualTo(8f * PropThrow.VelocityScale - 1e-3f), "never slower than the hand");
            Assert.That(Vector3.Angle(v, dir), Is.LessThan(1f), "along the hand, not bent toward the ground");
        }

        [Test]
        public void OnlyTheForwardPartOfTheLeverVelocityIsAdded()
        {
            // A prop held up and back: ω × r has a forward part (adds) and a sideways (up) part (dropped).
            var v = PropThrow.Linear(Vector3.forward * 7f, Vector3.right * 8f, new Vector3(0f, 0.15f, -0.1f));
            Assert.That(v.magnitude, Is.EqualTo((7f + 8f * 0.15f) * PropThrow.VelocityScale).Within(1e-3f));
            Assert.That(Vector3.Angle(v, Vector3.forward), Is.LessThan(1e-2f));
        }

        [Test]
        public void NoSpinOrNoLeverIsJustTheHandsVelocity()
        {
            Assert.That(PropThrow.Linear(Vector3.forward * 7f, Vector3.zero, Vector3.up * 0.2f), Is.EqualTo(PropThrow.Linear(Vector3.forward * 7f)));
            Assert.That(PropThrow.Linear(Vector3.forward * 7f, Vector3.right * 8f, Vector3.zero), Is.EqualTo(PropThrow.Linear(Vector3.forward * 7f)));
        }

        [Test]
        public void TheLeverIsCappedLikeEveryThrow()
        {
            Assert.That(PropThrow.Linear(Vector3.forward * 25f, Vector3.right * 100f, Vector3.up * 0.2f).magnitude, Is.EqualTo(PropThrow.MaxSpeed).Within(1e-4f));
        }

        [Test]
        public void TheHeldCentreIsWhereTheAttachPointMeetsTheHand()
        {
            // The prop's attach point is 10 cm below its pivot, turned 90° about Y; the hand's attach is at (1, 1, 0).
            var attachLocal = new Pose(new Vector3(0f, -0.1f, 0f), Quaternion.Euler(0f, 90f, 0f));
            var hand = new Pose(new Vector3(1f, 1f, 0f), Quaternion.identity);
            var com = new Vector3(0f, 0.1f, 0.05f);
            var c = PropThrow.HeldCenter(hand, attachLocal, com);
            var rotation = Quaternion.Inverse(attachLocal.rotation);
            var pivot = hand.position - rotation * attachLocal.position;
            Assert.That((c - (pivot + rotation * com)).magnitude, Is.LessThan(1e-5f));
            Assert.That((pivot - new Vector3(1f, 1.1f, 0f)).magnitude, Is.LessThan(1e-5f), "pivot 10 cm above the hand");
        }
    }
}
