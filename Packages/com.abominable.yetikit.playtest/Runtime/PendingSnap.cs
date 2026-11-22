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
        public string Id { get; }

        internal PendingSnap(SnitchCam owner, DeferredSnapBatch batch, string id, double deadline) =>
            (this.owner, Batch, Id, Deadline) = (owner, batch, id, deadline);

        /// <summary>Copy a fully encoded WAV, replacing any previous note. The note is submitted only by Publish.</summary>
        public bool AttachNote(byte[] wave)
        {
            if (owner == null || !SnapDelivery.ValidBytes(wave)) return false;
            Note = (byte[])wave.Clone();
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
