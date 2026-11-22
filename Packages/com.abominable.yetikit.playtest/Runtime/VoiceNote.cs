using System;

namespace YetiKit.Playtest
{
    public enum NoteEnd { None, Silence, SendIt, Maximum, Backup }

    /// <summary>Note lifetime measured in 16 kHz PCM samples, starting at Start (excluding host pre-roll).</summary>
    public sealed class VoiceNote
    {
        public const int SilenceSeconds = 3, BackupSeconds = 8, MaximumSeconds = 90;
        const int Rate = VoiceActivity.SampleRate, MaximumSamples = MaximumSeconds * Rate;
        VoiceActivity activity;
        int lastActivity;
        bool recognized;
        public bool Active => activity != null;
        public int SamplesConsumed { get; private set; }

        public void Start(bool phraseDetected = false)
        {
            activity = new VoiceActivity();
            SamplesConsumed = lastActivity = 0;
            recognized = phraseDetected;
        }

        /// <summary>A recognized phrase at the current sample cursor starts the shorter quiet timeout.</summary>
        public void MarkPhrase()
        {
            if (!Active) return;
            recognized = true;
            lastActivity = SamplesConsumed;
        }

        public NoteEnd Send() => Active ? Stop(NoteEnd.SendIt) : NoteEnd.None;

        /// <summary>Feed ordered PCM; only complete VAD frames count as speech. The SamplesConsumed delta is the WAV prefix length.</summary>
        public NoteEnd Process(short[] pcm, int offset, int count)
        {
            VoiceActivity.ValidateSlice(pcm, offset, count);
            if (!Active) return NoteEnd.None;
            int quietLimit = (recognized ? SilenceSeconds : BackupSeconds) * Rate;
            while (count > 0)
            {
                int untilFrame = VoiceActivity.FrameSamples - SamplesConsumed % VoiceActivity.FrameSamples;
                int untilStop = Math.Min(MaximumSamples, lastActivity + quietLimit) - SamplesConsumed;
                int take = Math.Min(count, Math.Min(untilFrame, untilStop));
                if (activity.Process(pcm, offset, take, out _)) lastActivity = SamplesConsumed + take;
                SamplesConsumed += take;
                if (SamplesConsumed == MaximumSamples) return Stop(NoteEnd.Maximum);
                if (SamplesConsumed - lastActivity == quietLimit) return Stop(recognized ? NoteEnd.Silence : NoteEnd.Backup);
                offset += take;
                count -= take;
            }
            return NoteEnd.None;
        }
        NoteEnd Stop(NoteEnd reason) { activity = null; return reason; }
    }
}
