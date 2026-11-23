using System;

namespace YetiKit.Playtest
{
    /// <summary>Streaming RMS detector for 10 ms frames of 16 kHz mono PCM16.</summary>
    public sealed class VoiceActivity
    {
        public const int SampleRate = 16000, FrameSamples = 160;
        const int QuietFrames = 30, ThresholdSquared = 600 * 600;
        int pending, quiet;
        long sumSquares;
        long frameOnset = -1;
        public long SamplesProcessed { get; private set; }
        internal long LastVoicedEndSample { get; private set; } = -1;

        /// <summary>Returns true if a complete voiced frame occurred. Reports the first voiced frame's onset after
        /// 300 ms of observed quiet, or -1 if that boundary was not observed.</summary>
        public bool Process(short[] pcm, int offset, int count, out long onsetSample)
        {
            ValidateSlice(pcm, offset, count);
            onsetSample = -1;
            bool voiced = false;
            for (int i = offset; i < offset + count; i++)
            {
                int energy = pcm[i] * pcm[i];
                sumSquares += energy;
                if (frameOnset < 0 && energy > ThresholdSquared) frameOnset = SamplesProcessed;
                SamplesProcessed++;
                if (++pending < FrameSamples) continue;
                if (sumSquares > (long)ThresholdSquared * FrameSamples)
                {
                    if (!voiced && quiet == QuietFrames) onsetSample = frameOnset;
                    voiced = true;
                    LastVoicedEndSample = SamplesProcessed;
                    quiet = 0;
                }
                else if (quiet < QuietFrames) quiet++;
                pending = 0;
                sumSquares = 0;
                frameOnset = -1;
            }
            return voiced;
        }

        internal static void ValidateSlice(short[] pcm, int offset, int count)
        {
            if (pcm == null) throw new ArgumentNullException(nameof(pcm));
            if (offset < 0 || offset > pcm.Length) throw new ArgumentOutOfRangeException(nameof(offset));
            if (count < 0 || count > pcm.Length - offset) throw new ArgumentOutOfRangeException(nameof(count));
        }
    }
}
