#if UNITY_EDITOR || YETIKIT_DEV
namespace YetiKit.Playtest
{
    /// <summary>A captured, locally staged snap. Use on the main thread until publish, cancel or expiry.</summary>
    public sealed class PendingSnap
    {
        SnitchCam owner;
        internal readonly DeferredSnapBatch Batch;
        internal readonly double Deadline;
        internal byte[] Note { get; private set; }
        internal double NoteTrimLeadMs { get; private set; }
        internal double NoteTrimTailMs { get; private set; }
        public string Id { get; }

        internal PendingSnap(SnitchCam owner, DeferredSnapBatch batch, string id, double deadline) =>
            (this.owner, Batch, Id, Deadline) = (owner, batch, id, deadline);

        /// <summary>Copy a fully encoded WAV, replacing any previous note. The note is submitted only by Publish.</summary>
        public bool AttachNote(byte[] wave)
        {
            if (owner == null || !SnapDelivery.ValidBytes(wave)) return false;
            Note = (byte[])wave.Clone();
            NoteTrimLeadMs = NoteTrimTailMs = 0;
            return true;
        }

        /// <summary>Encode 16 kHz mono PCM16, optionally removing triggers at either edge.
        /// Ranges are relative to the start of this PCM, including any retained pre-roll.</summary>
        public bool AttachNotePcm(short[] pcm, NoteTriggerRange? leading = null, NoteTriggerRange? trailing = null)
        {
            if (owner == null || pcm == null || pcm.Length == 0) return false;
            const int rate = VoiceActivity.SampleRate;
            var (offset, count, _) = VoiceNoteTrim.Select(pcm, rate, 1, leading, trailing);
            Note = WaveEncoder.Encode(pcm, offset, count);
            NoteTrimLeadMs = VoiceNoteTrim.ToMilliseconds(offset, rate);
            NoteTrimTailMs = VoiceNoteTrim.ToMilliseconds(pcm.Length - offset - count, rate);
            return true;
        }

        /// <summary>Start local publication. Use SnapOutcome for the result, or TryShutdown to drain it.</summary>
        public bool Publish() => owner?.PublishPending(withNote: true) ?? false;

        /// <summary>Discard the staged snap. On storage failure this returns false and can be retried.</summary>
        public bool Cancel() => owner?.CancelPending() ?? false;

        internal void Close() { owner = null; Note = null; }
    }
}
#endif
