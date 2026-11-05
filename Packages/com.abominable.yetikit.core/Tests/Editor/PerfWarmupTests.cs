using NUnit.Framework;

namespace YetiKit.Core.Tests
{
    /// <summary>
    /// A launch line once read drawCalls=32 / tris=84k against ~94 / ~200k later: the first sample was taken before the
    /// scene finished loading. The performance logger now waits for the scene and a few rendered frames.
    /// </summary>
    public class PerfWarmupTests
    {
        [Test]
        public void StaysClosedWhileTheSceneLoads()
        {
            var gate = new PerfWarmup(frames: 3);
            for (var i = 0; i < 100; i++) Assert.IsFalse(gate.Tick(sceneLoaded: false));
            Assert.IsFalse(gate.Open);
        }

        [Test]
        public void OpensAfterTheFramesWithTheSceneLoadedAndStaysOpen()
        {
            var gate = new PerfWarmup(frames: 3);
            Assert.IsFalse(gate.Tick(true));
            Assert.IsFalse(gate.Tick(true));
            Assert.IsTrue(gate.Tick(true), "third loaded frame");
            Assert.IsTrue(gate.Tick(false), "once open it stays open");
            Assert.IsTrue(gate.Open);
        }

        [Test]
        public void AnUnloadedFrameRestartsTheCount()
        {
            var gate = new PerfWarmup(frames: 3);
            gate.Tick(true);
            gate.Tick(true);
            gate.Tick(false);
            gate.Tick(true);
            Assert.IsFalse(gate.Tick(true));
            Assert.IsTrue(gate.Tick(true));
        }

        [Test]
        public void TheDefaultWaitsAFewFrames() => Assert.That(new PerfWarmup().Frames, Is.GreaterThanOrEqualTo(10));
    }
}
