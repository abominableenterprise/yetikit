using System;

namespace YetiKit.Playtest
{
    /// <summary>Half-open trigger interval in sample frames relative to the start of the note PCM.</summary>
    public readonly struct NoteTriggerRange
    {
        public readonly long StartSample, EndSample;
        public NoteTriggerRange(long startSample, long endSample) => (StartSample, EndSample) = (startSample, endSample);
    }

    /// <summary>Selects a slice of interleaved PCM16 without mutating or copying it.</summary>
    public static class VoiceNoteTrim
    {
        public const int PadMilliseconds = 50, MinimumMilliseconds = 250;
        const int MillisecondsPerSecond = 1000;

        /// <summary>Discard everything through the leading trigger's padded end and from the trailing
        /// trigger's padded start. Ignore ranges that don't intersect the note. Return the full slice
        /// if trimming would leave less than the minimum. Offset and count index individual PCM values.</summary>
        public static (int offset, int count, bool trimmed) Select(short[] pcm, int sampleRate, int channels,
            NoteTriggerRange? leading = null, NoteTriggerRange? trailing = null)
        {
            if (pcm == null) throw new ArgumentNullException(nameof(pcm));
            if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
            if (channels <= 0) throw new ArgumentOutOfRangeException(nameof(channels));
            if (pcm.Length % channels != 0) throw new ArgumentException("PCM must contain whole frames.", nameof(pcm));
            int frames = pcm.Length / channels;
            long pad = FramesFor(PadMilliseconds, sampleRate);
            long start = 0, end = frames;
            if (leading is NoteTriggerRange lead && Intersects(lead, frames))
                start = Math.Min(frames, Math.Min(lead.EndSample, frames) + pad);
            if (trailing is NoteTriggerRange tail && Intersects(tail, frames))
                end = Math.Max(0L, Math.Max(tail.StartSample, 0L) - pad);
            if ((start == 0 && end == frames) || end - start < FramesFor(MinimumMilliseconds, sampleRate))
                return (0, pcm.Length, false);
            return ((int)start * channels, (int)(end - start) * channels, true);
        }

        internal static double ToMilliseconds(int frames, int rate) => (double)frames * MillisecondsPerSecond / rate;
        static long FramesFor(int milliseconds, int rate) => ((long)milliseconds * rate + MillisecondsPerSecond - 1) / MillisecondsPerSecond;
        static bool Intersects(NoteTriggerRange range, int frames) => frames > 0 &&
            range.StartSample < range.EndSample && range.EndSample > 0 && range.StartSample < frames;
    }
}
