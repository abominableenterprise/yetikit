namespace YetiKit.Playtest
{
    /// <summary>
    /// A fixed-rate accumulator (pure): <see cref="Tick"/> adds the frame time and says whether a sample is due this
    /// frame. At most one sample per frame; a long frame (a hitch, a pause) drops the backlog instead of bursting.
    /// </summary>
    public sealed class FixedRateSampler
    {
        public readonly double Interval;
        double accumulated;

        public FixedRateSampler(double hz) => Interval = 1.0 / hz;

        /// <summary>Samples taken so far.</summary>
        public long Count { get; private set; }

        public bool Tick(double dt)
        {
            if (dt > 0) accumulated += dt;
            if (accumulated < Interval) return false;
            accumulated -= Interval;
            if (accumulated >= Interval) accumulated = 0; // behind by more than a sample: drop the backlog, don't burst
            Count++;
            return true;
        }

        public void Reset()
        {
            accumulated = 0;
            Count = 0;
        }
    }
}
