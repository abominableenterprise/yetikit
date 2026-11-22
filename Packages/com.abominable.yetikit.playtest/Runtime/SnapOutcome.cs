#if UNITY_EDITOR || YETIKIT_DEV
using System.Collections.Concurrent;

namespace YetiKit.Playtest
{
    public enum SnapStatus { Queued, Sent, Local, Failed }

    public sealed class SnapOutcome
    {
        public readonly struct Result
        {
            public readonly string Session, Snap;
            public readonly SnapStatus Status;
            public Result(string session, string snap, SnapStatus status) => (Session, Snap, Status) = (session, snap, status);
        }

        readonly ConcurrentQueue<Result> pending = new();
        public void Post(Result result) => pending.Enqueue(result);
        /// <summary>Drain from the host's main thread; transitions are not coalesced.</summary>
        public bool TryTake(out Result result) => pending.TryDequeue(out result);
    }
}
#endif
