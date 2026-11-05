using System;

namespace YetiKit.Core
{
    /// <summary>
    /// Holds one <see cref="IPerfCounter"/> for the performance logger (pure). The first <see cref="Tick"/> starts it. While it
    /// has never been valid (a ProfilerRecorder started before its counter exists stays invalid), the slot disposes it
    /// and starts a new one, at most once every <see cref="RetrySeconds"/>. Once a counter has been valid it is kept for
    /// good: never restarted, whatever it reads. A fresh recorder holds no samples until a frame ends, so restarting a
    /// working one when the render group reads all 0 on one frame only blanks it again.
    /// <para>Every <see cref="Tick"/> folds the counter's held frame samples into <see cref="IntervalMax"/>, so a
    /// frame that reads 0 (on the Quest the render stats are 0 on many frames) does not blank the logged line.</para>
    /// </summary>
    public sealed class PerfCounterSlot
    {
        public readonly string Name;
        public readonly float RetrySeconds;
        readonly Func<IPerfCounter> start;
        IPerfCounter counter;
        float nextStart = float.NegativeInfinity;
        bool everValid;

        public PerfCounterSlot(string name, Func<IPerfCounter> start, float retrySeconds)
        {
            Name = name;
            this.start = start;
            RetrySeconds = retrySeconds;
        }

        /// <summary>How many counters this slot has started.</summary>
        public int Starts { get; private set; }

        /// <summary>True once the counter has been valid (sticky: a valid counter is never dropped).</summary>
        public bool Valid => everValid;

        /// <summary>The newest frame sample seen (kept when a later frame holds no sample).</summary>
        public long LastValue { get; private set; }

        /// <summary>The largest frame sample seen since the last <see cref="TakeIntervalMax"/>.</summary>
        public long IntervalMax { get; private set; }

        /// <summary>The largest frame sample ever seen: above 0 once the counter has carried a real number.</summary>
        public long PeakValue { get; private set; }

        /// <summary>
        /// Call once per frame. Starts the counter, restarts it while it has never been valid and the retry time has
        /// come, and reads the samples of a valid one.
        /// </summary>
        public void Tick(float now)
        {
            if (!everValid && now >= nextStart && (counter == null || !counter.Valid))
            {
                counter?.Dispose();
                counter = start();
                Starts++;
                nextStart = now + RetrySeconds;
            }
            if (counter == null || !counter.Valid) return;
            everValid = true;
            if (counter.Count == 0) return; // bound, but no frame has ended since it started
            LastValue = counter.LastValue;
            var max = counter.MaxValue;
            if (max > IntervalMax) IntervalMax = max;
            if (max > PeakValue) PeakValue = max;
        }

        /// <summary>
        /// The largest frame sample since the last call (0 when none was above 0), and starts a new interval.
        /// Clears the recorder's held samples too, so an old peak cannot enter the next interval (or return after
        /// warm-up is discarded). The recorder stays bound; LastValue and the lifetime PeakValue are preserved.
        /// </summary>
        public long TakeIntervalMax()
        {
            var v = IntervalMax;
            IntervalMax = 0;
            counter?.ResetSamples();
            return v;
        }

        public void Dispose()
        {
            counter?.Dispose();
            counter = null;
            everValid = false;
            nextStart = float.NegativeInfinity;
            LastValue = IntervalMax = PeakValue = 0;
        }
    }
}
