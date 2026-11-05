namespace YetiKit.Core
{
    /// <summary>The uploader's retry delay (pure): 5 s after the first failure, doubling, at most 5 min, forever.</summary>
    public static class Backoff
    {
        public const double First = 5, Max = 300;

        /// <summary>Seconds to wait after <paramref name="failures"/> failures in a row (0: none).</summary>
        public static double Delay(int failures)
        {
            if (failures <= 0) return 0;
            var d = First;
            for (var i = 1; i < failures && d < Max; i++) d *= 2;
            return d < Max ? d : Max;
        }
    }
}
