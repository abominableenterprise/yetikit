#if UNITY_EDITOR || YETIKIT_DEV
namespace YetiKit.Playtest
{
    public static class SnapAnchor
    {
        /// <summary>Converts a zero-based PCM sample index to frame-clock seconds. Use the time
        /// of sample zero of the recognition stream, on the same clock passed to SnitchCam.Tick.
        /// Returns null for an unavailable onset or invalid clock or sample rate.</summary>
        public static double? FromSample(long onsetSample, int sampleRate, double micStartOnFrameClock)
        {
            if (onsetSample < 0 || sampleRate <= 0) return null;
            var time = micStartOnFrameClock + onsetSample / (double)sampleRate;
            return IsFinite(time) ? time : (double?)null;
        }

        internal static bool IsFinite(double time) => !double.IsNaN(time) && !double.IsInfinity(time);
    }
}
#endif
