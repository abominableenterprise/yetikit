#if UNITY_EDITOR || YETIKIT_DEV
using System.Collections.Concurrent;
namespace YetiKit.Playtest
{
    public enum SnapStatus { Queued, Sent, Local, Failed }
    public sealed class SnapOutcome
    {
        readonly ConcurrentQueue<(string Session, string Snap, SnapStatus Status)> pending = new();
        public void Post((string Session, string Snap, SnapStatus Status) result) => pending.Enqueue(result);
        public bool TryTake(out (string Session, string Snap, SnapStatus Status) result) => pending.TryDequeue(out result);
    }
}
#endif
