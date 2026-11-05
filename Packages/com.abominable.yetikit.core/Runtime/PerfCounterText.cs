namespace YetiKit.Core
{
    /// <summary>
    /// How the performance logger prints the render counters (pure). The Render ProfilerRecorders ("Draw Calls Count",
    /// "SetPass Calls Count", "Batches Count", "Triangles Count", "Vertices Count") can read 0 or be invalid on the Quest
    /// (started before the counter exists, or render stats not gathered). A frame that drew anything has triangles, so
    /// while every valid counter has only ever read 0 (the performance logger passes each slot's peak, so a quiet frame or
    /// interval later does not count) the group is "not measured" and prints "n/a" instead of a misleading 0. A
    /// counter that is itself invalid prints "n/a" on its own, without hiding the valid ones.
    /// </summary>
    public static class PerfCounterText
    {
        public const string NotAvailable = "n/a";

        /// <summary>True when the render group carries real numbers: at least one valid counter reads more than 0.</summary>
        public static bool RenderCountersMeasured(bool[] valid, long[] values)
        {
            if (valid == null || values == null || valid.Length == 0 || valid.Length != values.Length) return false;
            for (var i = 0; i < valid.Length; i++)
                if (valid[i] && values[i] > 0) return true;
            return false;
        }

        /// <summary>The value, or "n/a" when the render group is not measured.</summary>
        public static string Format(long value, bool measured) => measured ? value.ToString() : NotAvailable;

        /// <summary>The value, or "n/a" when this counter is invalid or the render group is not measured.</summary>
        public static string Format(long value, bool valid, bool measured) => Format(value, valid && measured);
    }
}
