using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class SnapAnchorTests
    {
        [TestCase(0, 16000, 10, 10)]
        [TestCase(4800, 16000, 10, 10.3)]
        [TestCase(12000, 48000, 10, 10.25)]
        public void MapsSampleOffsetToFrameClock(long sample, int rate, double start, double expected)
        {
            Assert.That(SnapAnchor.FromSample(sample, rate, start), Is.EqualTo(expected).Within(1e-9));
        }

        [TestCase(-1, 16000, 10)]
        [TestCase(0, 0, 10)]
        [TestCase(0, -1, 10)]
        [TestCase(0, 16000, double.NaN)]
        [TestCase(0, 16000, double.PositiveInfinity)]
        public void UnavailableOnsetHasNoAnchor(long sample, int rate, double start)
        {
            Assert.That(SnapAnchor.FromSample(sample, rate, start), Is.Null);
        }

        [TestCase(1, "oldest", 1)]
        [TestCase(1.2, "oldest", 1)]
        [TestCase(1.375, "newest", 1.5)]
        [TestCase(1.75, "newest", 1.5)]
        public void SelectsNearestRetainedFrame(double anchor, string expectedFrame, double expectedTime)
        {
            Assert.That(History().TryClosestInRange(anchor, out var frame, out var time), Is.True);
            Assert.That((frame, time), Is.EqualTo((expectedFrame, expectedTime)));
        }

        [TestCase(0.99)]
        [TestCase(1.751)]
        [TestCase(double.NaN)]
        [TestCase(double.PositiveInfinity)]
        public void RejectsAnchorOutsideRetainedHistory(double anchor)
        {
            Assert.That(History().TryClosestInRange(anchor, out _, out _), Is.False);
        }

        [Test]
        public void EmptyHistoryHasNoNearestFrame()
        {
            Assert.That(new FrameSelection<string>(3).TryClosestInRange(1, out _, out _), Is.False);
        }

        static FrameSelection<string> History()
        {
            var ring = new FrameSelection<string>(3);
            ring.Add(0.9, "evicted");
            ring.Add(1, "oldest");
            ring.Add(1.25, "middle");
            ring.Add(1.5, "newest");
            return ring;
        }
    }
}
