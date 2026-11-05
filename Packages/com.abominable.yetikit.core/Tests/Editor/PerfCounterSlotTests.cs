using System.Collections.Generic;
using NUnit.Framework;

namespace YetiKit.Core.Tests
{
    /// <summary>
    /// A performance logger started its ProfilerRecorders once, in OnEnable; on the Quest a recorder that started invalid
    /// left drawCalls/tris at "n/a" for the whole session. A slot now restarts it until it is valid. Round 2 (build 186):
    /// the slot also restarted a valid render group on any frame that read all 0, and the line used that one frame's
    /// LastValue, so one good line (drawCalls=94 tris=193903) was followed by n/a again. A valid counter is now kept and
    /// the line prints the interval's largest frame sample.
    /// </summary>
    [Category("PureUnityTest")]
    public class PerfCounterSlotTests
    {
        // Synthetic rolling-buffer capacity; no consumer logger dependency.
        const int RenderCapacity = 4;

        /// <summary>A counter with a fixed value, valid or not.</summary>
        sealed class FakeCounter : IPerfCounter
        {
            readonly bool valid;
            readonly long value;
            bool hasSample = true;
            public bool Disposed;

            public FakeCounter(bool valid, long value)
            {
                this.valid = valid;
                this.value = value;
            }

            public bool Valid => valid && !Disposed;
            public int Count => Valid && hasSample ? 1 : 0;
            public long LastValue => Count > 0 ? value : 0;
            public long MaxValue => LastValue;
            public void ResetSamples() => hasSample = false;
            public void Dispose() => Disposed = true;
        }

        /// <summary>
        /// Like a Quest render recorder: invalid for its first <see cref="invalidFrames"/> frames, then valid with no
        /// sample yet (Count 0), then one sample per frame from <see cref="frames"/>, many of them 0.
        /// </summary>
        sealed class QuestLikeCounter : IPerfCounter
        {
            readonly int invalidFrames;
            readonly long[] frames;
            int frame = -1;
            int clearedFrame = -1;
            public bool Disposed;

            public QuestLikeCounter(int invalidFrames, params long[] frames)
            {
                this.invalidFrames = invalidFrames;
                this.frames = frames;
            }

            /// <summary>One frame ends.</summary>
            public void Step() => frame++;

            int SampleIndex => frame - invalidFrames - 1; // the first valid frame has no sample yet
            public bool Valid => !Disposed && frame >= invalidFrames;
            public int Count => Valid && SampleIndex >= 0 && frame > clearedFrame ? 1 : 0;
            public long LastValue => Count > 0 ? frames[SampleIndex % frames.Length] : 0;
            public long MaxValue => LastValue;
            public void ResetSamples() => clearedFrame = frame;
            public void Dispose() => Disposed = true;
        }

        /// <summary>A rolling buffer with the same capacity as the production render recorders.</summary>
        sealed class BufferedCounter : IPerfCounter
        {
            readonly List<long> samples = new List<long>();
            public bool Valid => true;
            public int Count => samples.Count;
            public long LastValue => Count > 0 ? samples[Count - 1] : 0;
            public long MaxValue
            {
                get
                {
                    long max = 0;
                    foreach (var sample in samples)
                        if (sample > max) max = sample;
                    return max;
                }
            }

            public void Step(long value)
            {
                if (Count == RenderCapacity) samples.RemoveAt(0);
                samples.Add(value);
            }

            public void ResetSamples() => samples.Clear();
            public void Dispose() { }
        }

        sealed class FakeSource
        {
            readonly int invalidStarts;
            readonly long value;
            public readonly List<FakeCounter> Started = new List<FakeCounter>();

            public FakeSource(int invalidStarts, long value = 94)
            {
                this.invalidStarts = invalidStarts;
                this.value = value;
            }

            public IPerfCounter Start()
            {
                var c = new FakeCounter(Started.Count >= invalidStarts, value);
                Started.Add(c);
                return c;
            }
        }

        [Test]
        public void AnInvalidCounterIsRestartedEveryRetryUntilValidThenKept()
        {
            var src = new FakeSource(invalidStarts: 3);
            var slot = new PerfCounterSlot("Draw Calls Count", src.Start, retrySeconds: 2f);
            float t;
            for (t = 0f; t < 20f && !slot.Valid; t += 0.1f) slot.Tick(t);

            Assert.IsTrue(slot.Valid, "valid after the counter starts existing");
            Assert.AreEqual(94, slot.LastValue);
            Assert.AreEqual(4, src.Started.Count, "3 invalid starts, then the valid one");
            Assert.That(t, Is.InRange(6f, 6.3f), "one restart every 2 s, not every frame");
            for (var i = 0; i < 3; i++) Assert.IsTrue(src.Started[i].Disposed, "an invalid recorder is disposed before the next");

            for (var u = t; u < t + 60f; u += 0.5f) slot.Tick(u);
            Assert.AreEqual(4, src.Started.Count, "a valid counter is kept");
            Assert.IsFalse(src.Started[3].Disposed);
        }

        [Test]
        public void ACounterThePlatformNeverHasStaysNotValid()
        {
            var src = new FakeSource(invalidStarts: int.MaxValue);
            var slot = new PerfCounterSlot("SetPass Calls Count", src.Start, retrySeconds: 2f);
            for (var t = 0f; t < 10f; t += 0.5f) slot.Tick(t);

            Assert.IsFalse(slot.Valid);
            Assert.AreEqual(0, slot.LastValue);
            Assert.AreEqual(5, src.Started.Count, "starts at 0, 2, 4, 6 and 8 s");
            Assert.AreEqual(PerfCounterText.NotAvailable, PerfCounterText.Format(slot.LastValue, slot.Valid, measured: true));
        }

        [Test]
        public void AValidCounterIsNeverRestartedAndItsZeroFramesDoNotBlankTheLine()
        {
            var started = new List<QuestLikeCounter>();
            QuestLikeCounter c = null;
            var slot = new PerfCounterSlot("Draw Calls Count", () =>
            {
                // the first recorder never binds; the second binds after 3 frames, then reads 94 on one frame in four
                c = new QuestLikeCounter(started.Count == 0 ? int.MaxValue : 3, 0, 0, 94, 0);
                started.Add(c);
                return c;
            }, retrySeconds: 2f);

            const float dt = 1f / 72f;
            var lines = new List<string>();
            var t = 0f;
            for (var line = 0; line < 10; line++)
            {
                for (var end = t + 5f; t < end; t += dt)
                {
                    c?.Step();
                    slot.Tick(t);
                }
                var measured = PerfCounterText.RenderCountersMeasured(new[] { slot.Valid }, new[] { slot.PeakValue });
                lines.Add(PerfCounterText.Format(slot.TakeIntervalMax(), slot.Valid, measured));
            }

            Assert.AreEqual(2, started.Count, "one invalid start, then the valid one is kept for good");
            Assert.IsTrue(started[0].Disposed, "the invalid recorder is disposed");
            Assert.IsFalse(started[1].Disposed, "a recorder that has been valid is never disposed");
            Assert.IsTrue(slot.Valid);
            Assert.AreEqual(94, slot.PeakValue);
            CollectionAssert.AreEqual(new[] { "94", "94", "94", "94", "94", "94", "94", "94", "94", "94" }, lines,
                "every line carries the interval's largest frame, not the 0 of the frame it was written on");
        }

        [Test]
        public void AValidCounterThatGoesQuietKeepsItsLastNumberAndStaysValid()
        {
            var c = new QuestLikeCounter(0, 94, 0, 0, 0, 0, 0, 0, 0);
            var starts = 0;
            var slot = new PerfCounterSlot("Triangles Count", () => { starts++; return c; }, retrySeconds: 2f);
            for (var f = 0; f < 3; f++)
            {
                c.Step();
                slot.Tick(f);
            }
            Assert.AreEqual(94, slot.TakeIntervalMax());
            for (var f = 3; f < 8; f++)
            {
                c.Step();
                slot.Tick(f);
            }
            Assert.IsTrue(slot.Valid, "zero frames do not make a valid counter invalid");
            Assert.AreEqual(1, starts, "and do not restart it");
            Assert.AreEqual(0, slot.LastValue, "the newest frame read 0");
            Assert.AreEqual(0, slot.TakeIntervalMax(), "an interval of only 0 frames reports 0");
            Assert.AreEqual(94, slot.PeakValue, "the group stays measured");
            Assert.AreEqual("0", PerfCounterText.Format(0, slot.Valid, PerfCounterText.RenderCountersMeasured(
                new[] { slot.Valid }, new[] { slot.PeakValue })), "a measured 0, not n/a");
        }

        [Test]
        public void APeakOnTheLastFrameIsNotCountedInTheNextInterval()
        {
            var c = new BufferedCounter();
            var slot = new PerfCounterSlot("Draw Calls Count", () => c, retrySeconds: 2f);
            for (var f = 0; f < RenderCapacity; f++)
            {
                c.Step(f == RenderCapacity - 1 ? 94 : 0);
                slot.Tick(f);
            }
            Assert.AreEqual(94, slot.TakeIntervalMax(), "the last frame belongs to the interval just ended");
            Assert.AreEqual(94, slot.LastValue, "consuming the interval preserves the latest reading");
            Assert.AreEqual(0, slot.TakeIntervalMax(), "taking twice without a new frame is empty");

            for (var f = 0; f < RenderCapacity * 2; f++)
            {
                c.Step(0);
                slot.Tick(10 + f);
            }
            Assert.AreEqual(0, slot.TakeIntervalMax(), "the previous peak must not leak through the rolling buffer");
            Assert.AreEqual(94, slot.PeakValue, "lifetime measurement state survives interval boundaries");
            Assert.AreEqual(1, slot.Starts, "interval boundaries do not restart a valid recorder");

            c.Step(120);
            c.Step(0); // multiple samples between ticks are still included in the current interval
            slot.Tick(30f);
            Assert.AreEqual(120, slot.TakeIntervalMax(), "new samples are recorded after clearing the buffer");
            Assert.AreEqual(120, slot.PeakValue);
        }

        [Test]
        public void WarmupDiscardedSamplesNeverReappear()
        {
            var c = new BufferedCounter();
            var slot = new PerfCounterSlot("Draw Calls Count", () => c, retrySeconds: 2f);
            c.Step(94);
            slot.Tick(0f);
            slot.TakeIntervalMax(); // the performance logger drops the warm-up interval this way.

            for (var interval = 0; interval < 2; interval++)
            {
                for (var f = 0; f < RenderCapacity * 2; f++)
                {
                    c.Step(0);
                    slot.Tick(1 + interval * 10 + f);
                }
                Assert.AreEqual(0, slot.TakeIntervalMax(), "discarded warm-up samples cannot enter a logged interval");
            }
            Assert.IsTrue(slot.Valid);
            Assert.AreEqual(94, slot.PeakValue, "warm-up still establishes that the counter is measured");
        }

        [Test]
        public void AValidCounterWithNoSampleYetIsValidAndReadsZero()
        {
            var c = new QuestLikeCounter(0, 94);
            var slot = new PerfCounterSlot("Batches Count", () => c, retrySeconds: 2f);
            c.Step();
            slot.Tick(0f);
            Assert.AreEqual(0, c.Count, "bound, no frame ended yet");
            Assert.IsTrue(slot.Valid, "valid with 0 samples is still valid");
            Assert.AreEqual(0, slot.IntervalMax);
            c.Step();
            slot.Tick(0.1f);
            Assert.AreEqual(94, slot.IntervalMax);
        }

        [Test]
        public void ARealRecorderStartedBeforeItsMarkerExistsBecomesValid()
        {
            var name = "YetiKit perf probe " + System.Guid.NewGuid().ToString("N");
            var slot = new PerfCounterSlot(name, () => new ProfilerPerfCounter(Unity.Profiling.ProfilerCategory.Scripts, name), 2f);
            slot.Tick(0f);
            Assert.IsFalse(slot.Valid, "no such marker yet");
            var marker = new Unity.Profiling.ProfilerMarker(Unity.Profiling.ProfilerCategory.Scripts, name);
            marker.Begin();
            marker.End();
            slot.Tick(2f);
            Assert.IsTrue(slot.Valid, "bound once the marker exists");
            slot.Dispose();
        }

        [UnityEngine.TestTools.UnityTest]
        public System.Collections.IEnumerator ClearingARealRecorderKeepsItBoundAndCollecting()
        {
            var name = "YetiKit perf reset probe " + System.Guid.NewGuid().ToString("N");
            var marker = new Unity.Profiling.ProfilerMarker(Unity.Profiling.ProfilerCategory.Scripts, name);
            var c = new ProfilerPerfCounter(Unity.Profiling.ProfilerCategory.Scripts, name, RenderCapacity);
            try
            {
                for (var interval = 0; interval < 2; interval++)
                {
                    for (var frame = 0; frame < RenderCapacity; frame++)
                    {
                        marker.Begin();
                        marker.End();
                        yield return null;
                    }
                    Assert.IsTrue(c.Valid);
                    Assert.That(c.Count, Is.GreaterThan(0), "the recorder collects samples in each interval");
                    c.ResetSamples();
                    Assert.IsTrue(c.Valid, "clearing samples does not unbind the recorder");
                    Assert.AreEqual(0, c.Count, "no samples from the previous interval remain");
                    Assert.AreEqual(0, c.MaxValue);
                }
            }
            finally
            {
                c.Dispose();
            }
        }

        [Test]
        public void DisposeReleasesTheCounter()
        {
            var src = new FakeSource(invalidStarts: 0);
            var slot = new PerfCounterSlot("Vertices Count", src.Start, retrySeconds: 2f);
            slot.Tick(0f);
            slot.Dispose();
            Assert.IsTrue(src.Started[0].Disposed);
            Assert.IsFalse(slot.Valid);
        }
    }
}
