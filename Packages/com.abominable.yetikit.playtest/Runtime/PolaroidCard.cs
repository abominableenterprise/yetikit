#if UNITY_EDITOR || YETIKIT_DEV
using UnityEngine;
namespace YetiKit.Playtest
{
    public readonly struct PolaroidPose
    {
        public readonly Vector3 Offset;
        public readonly float Width, Alpha, Red;
        public PolaroidPose(Vector3 offset, float width, float alpha, float red = 0) => (Offset, Width, Alpha, Red) = (offset, width, alpha, red);
    }
    public enum PolaroidState { Gone, Capturing, Hovering, Queued, Local, Sent, Failed }
    public sealed class PolaroidCard
    {
        public const double ShrinkSeconds = 0.4, FlySeconds = 0.5, HoverTimeout = VoiceNote.MaximumSeconds + 30;
        static readonly Vector3 Hover = new(-0.2f, -0.19f, 0.6f);
        public PolaroidState State { get; private set; }
        public bool Visible => State != PolaroidState.Gone;
        (string snap, double since, PolaroidState next) pending;
        public void Start(string id, double now) { pending = (id, now, PolaroidState.Hovering); State = PolaroidState.Capturing; }
        internal void Hide() => State = PolaroidState.Gone;
        internal void Cancel(string id) { if (id == pending.snap) Hide(); }
        public bool SetStatus(string id, SnapStatus status, double now)
        {
            if (id != pending.snap || Tick(now).Alpha <= 0 || pending.next is PolaroidState.Local or PolaroidState.Sent or PolaroidState.Failed) return false;
            var state = status switch { SnapStatus.Queued => PolaroidState.Queued, SnapStatus.Local => PolaroidState.Local,
                SnapStatus.Failed => PolaroidState.Failed, SnapStatus.Sent => PolaroidState.Sent, _ => pending.next };
            if (state == pending.next) return false;
            pending.next = state;
            if (State != PolaroidState.Capturing) (State, pending.since) = (state, now);
            return true;
        }
        public PolaroidPose Tick(double now)
        {
            if (State == PolaroidState.Capturing && now >= pending.since + ShrinkSeconds) (State, pending.since) = (pending.next, pending.since + ShrinkSeconds);
            float t = (float)(now - pending.since), shrink = Mathf.Clamp01(t / (float)ShrinkSeconds), fly = Mathf.Pow(Mathf.Clamp01(t / (float)FlySeconds), 2);
            if (State == PolaroidState.Capturing) return new(Vector3.Lerp(Vector3.forward * 0.8f, Hover, shrink), Mathf.Lerp(0.6f, 0.15f, shrink), 1);
            double end = State switch { PolaroidState.Hovering => HoverTimeout, PolaroidState.Sent => FlySeconds, PolaroidState.Failed => 1.9, PolaroidState.Gone => 0, _ => 3.4 };
            float alpha = Visible ? Mathf.Clamp01((float)((pending.since + end - now) / (State == PolaroidState.Sent ? 0.125 : 0.4))) : 0;
            if (alpha <= 0) { Hide(); return default; }
            float red = State == PolaroidState.Failed ? Mathf.Clamp01(t / 0.15f) : 0;
            return new(Hover + (State == PolaroidState.Sent ? new Vector3(-0.3f, 1.3f, 0) * fly : Vector3.down * (red * 0.06f)), 0.15f, alpha, red);
        }
    }
}
#endif
