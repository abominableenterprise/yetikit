using NUnit.Framework;

namespace YetiKit.Core.Tests
{
    /// <summary>
    /// A performance logger on the Quest logged drawCalls=0: the Render ProfilerRecorders stay at 0 (or invalid) when the
    /// player doesn't gather render stats. Those numbers now print "n/a" instead of a misleading 0.
    /// </summary>
    public class PerfCounterTextTests
    {
        [Test]
        public void AllZeroRenderCountersAreNotMeasured()
        {
            Assert.IsFalse(PerfCounterText.RenderCountersMeasured(new[] { true, true, true, true, true }, new long[5]));
            Assert.AreEqual("n/a", PerfCounterText.Format(0, measured: false));
        }

        [Test]
        public void AnInvalidRecorderPrintsNaOnItsOwn()
        {
            Assert.IsTrue(PerfCounterText.RenderCountersMeasured(new[] { true, false, true, true, true }, new long[] { 120, 0, 90, 200000, 300000 }),
                "one counter the platform lacks does not hide the others");
            Assert.AreEqual("n/a", PerfCounterText.Format(0, valid: false, measured: true));
            Assert.AreEqual("120", PerfCounterText.Format(120, valid: true, measured: true));
            Assert.IsFalse(PerfCounterText.RenderCountersMeasured(new[] { false, false, false, false, false }, new long[5]));
            Assert.IsFalse(PerfCounterText.RenderCountersMeasured(new bool[0], new long[0]));
            Assert.IsFalse(PerfCounterText.RenderCountersMeasured(null, null));
        }

        [Test]
        public void RealCountersPrintTheirValue()
        {
            Assert.IsTrue(PerfCounterText.RenderCountersMeasured(new[] { true, true, true, true, true }, new long[] { 132, 40, 90, 249451, 300000 }));
            Assert.AreEqual("132", PerfCounterText.Format(132, measured: true));
            Assert.AreEqual("0", PerfCounterText.Format(0, measured: true), "a measured 0 (e.g. setPass) stays 0");
        }
    }
}
