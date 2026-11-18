using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Hands.Tests
{
    /// <summary>Joint curls and hand shape classification from synthetic joint positions.</summary>
    public class HandShapeTests
    {
        /// <summary>
        /// A synthetic tracked hand in the <see cref="HandCurls"/> point order: the wrist at the origin, each finger a
        /// chain along +Z from its own base, every joint bent about X by <c>curl × FullBend</c>.
        /// </summary>
        public static Vector3[] Hand(float thumb, float index, float middle, float ring, float little)
        {
            var curls = new[] { thumb, index, middle, ring, little };
            var points = new Vector3[HandCurls.Points];
            var bone = new[] { 0.04f, 0.04f, 0.03f, 0.025f, 0.02f };
            for (var f = 0; f < FingerCurls.Fingers; f++)
            {
                var o = f * HandCurls.PointsPerFinger;
                var p = f == FingerCurls.Thumb ? Vector3.zero : new Vector3((f - 2) * 0.02f, 0f, 0.01f);
                var dir = Quaternion.identity;
                points[o] = p;
                for (var i = 1; i < HandCurls.PointsPerFinger; i++)
                {
                    if (i >= 2) dir *= Quaternion.AngleAxis(curls[f] * HandCurls.FullBend[f][i - 2], Vector3.right);
                    p += dir * Vector3.forward * bone[i];
                    points[o + i] = p;
                }
            }
            return points;
        }

        static FingerCurls Curls(Vector3[] points)
        {
            var c = new JointCurls();
            HandCurls.Measure(points, c);
            return HandCurls.PerFinger(c);
        }

        static HandShape Classify(params Vector3[][] frames)
        {
            var k = new HandShapeClassifier();
            foreach (var f in frames) k.Tick(Curls(f));
            return k.Shape;
        }

        [Test]
        public void CurlsComeBackFromTheJointPositions()
        {
            var c = new JointCurls();
            HandCurls.Measure(Hand(0.2f, 0.5f, 0f, 1f, 0.75f), c);
            for (var j = 0; j < JointCurls.Joints; j++)
            {
                Assert.That(c[FingerCurls.Thumb, j], Is.EqualTo(0.2f).Within(1e-3f));
                Assert.That(c[FingerCurls.Index, j], Is.EqualTo(0.5f).Within(1e-3f));
                Assert.That(c[FingerCurls.Middle, j], Is.EqualTo(0f).Within(1e-3f));
                Assert.That(c[FingerCurls.Ring, j], Is.EqualTo(1f).Within(1e-3f));
                Assert.That(c[FingerCurls.Pinky, j], Is.EqualTo(0.75f).Within(1e-3f));
            }
        }

        [Test]
        public void OverBentJointsClampToOne()
        {
            var c = new JointCurls();
            HandCurls.Measure(Hand(0f, 1.5f, 0f, 0f, 0f), c);
            Assert.That(c[FingerCurls.Index, 1], Is.EqualTo(1f));
        }

        [Test]
        public void Fist() => Assert.That(Classify(Hand(0.5f, 0.9f, 0.9f, 0.9f, 0.9f)), Is.EqualTo(HandShape.Fist));

        [Test]
        public void OpenPalm() => Assert.That(Classify(Hand(0f, 0.05f, 0.05f, 0.1f, 0.1f)), Is.EqualTo(HandShape.Open));

        [Test]
        public void MiddleOnlyWithTheThumbFree([Values(0f, 0.5f, 1f)] float thumb) =>
            Assert.That(Classify(Hand(thumb, 0.9f, 0.05f, 0.9f, 0.9f)), Is.EqualTo(HandShape.Bird));

        [Test]
        public void Point() => Assert.That(Classify(Hand(0.8f, 0.05f, 0.9f, 0.9f, 0.9f)), Is.EqualTo(HandShape.Point));

        [Test]
        public void RelaxedHalfCurlIsNothing() => Assert.That(Classify(Hand(0.3f, 0.4f, 0.4f, 0.45f, 0.5f)), Is.EqualTo(HandShape.Relaxed));

        [Test]
        public void MiddleOnlyIsNotAFistOrAnOpenHand()
        {
            var middleOnly = Curls(Hand(0f, 0.9f, 0.05f, 0.9f, 0.9f));
            Assert.That(HandShapeClassifier.Holds(HandShape.Fist, middleOnly, true), Is.False);
            Assert.That(HandShapeClassifier.Holds(HandShape.Open, middleOnly, true), Is.False);
            Assert.That(HandShapeClassifier.Holds(HandShape.Point, middleOnly, true), Is.False);
        }

        [Test]
        public void MiddleOnlyHysteresisKeepsItThroughAWobble()
        {
            // Middle finger at 0.38: too bent to enter Bird (0.3), straight enough to keep it (0.42).
            var wobble = Hand(0f, 0.9f, 0.38f, 0.9f, 0.9f);
            Assert.That(Classify(wobble), Is.EqualTo(HandShape.Relaxed), "not entered from a wobbly middle finger");
            Assert.That(Classify(Hand(0f, 0.9f, 0f, 0.9f, 0.9f), wobble), Is.EqualTo(HandShape.Bird), "kept");
            Assert.That(Classify(Hand(0f, 0.9f, 0f, 0.9f, 0.9f), Hand(0f, 0.9f, 0.7f, 0.9f, 0.9f)), Is.EqualTo(HandShape.Fist),
                "curling the middle finger changes Bird to Fist");
        }

        [Test]
        public void FistHysteresisKeepsItThroughALooseRing()
        {
            var loose = Hand(0.5f, 0.9f, 0.9f, 0.5f, 0.9f); // ring at 0.5: below 0.6 to enter, above 0.45 to stay
            Assert.That(Classify(loose), Is.EqualTo(HandShape.Relaxed));
            Assert.That(Classify(Hand(0.5f, 0.9f, 0.9f, 0.9f, 0.9f), loose), Is.EqualTo(HandShape.Fist));
            Assert.That(Classify(Hand(0.5f, 0.9f, 0.9f, 0.9f, 0.9f), Hand(0.5f, 0.9f, 0.9f, 0.3f, 0.9f)), Is.EqualTo(HandShape.Relaxed),
                "opening the ring finger past the stay threshold ends the fist");
        }

        [Test]
        public void OpenToFistToOpen()
        {
            var k = new HandShapeClassifier();
            Assert.That(k.Tick(Curls(Hand(0f, 0f, 0f, 0f, 0f))), Is.EqualTo(HandShape.Open));
            Assert.That(k.Tick(Curls(Hand(0.3f, 0.5f, 0.5f, 0.5f, 0.5f))), Is.EqualTo(HandShape.Relaxed), "half way: neither");
            Assert.That(k.Tick(Curls(Hand(0.8f, 1f, 1f, 1f, 1f))), Is.EqualTo(HandShape.Fist));
            Assert.That(k.Tick(Curls(Hand(0f, 0.1f, 0.1f, 0.1f, 0.1f))), Is.EqualTo(HandShape.Open));
            k.Reset();
            Assert.That(k.Shape, Is.EqualTo(HandShape.Relaxed));
        }
    }
}
