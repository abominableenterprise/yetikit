#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using UnityEngine;
namespace YetiKit.Playtest
{
    [Serializable] public struct SnapContext
    {
        public string session, build, scene, tuning, phrase, snap, frameSource;
        public Vector3 position;
        public Quaternion rotation;
        public double t, triggerT;
        public StripFrame[] strip;
        public int stripMain;
    }
    public interface ISnapContextProvider { SnapContext CaptureContext(); }
    // Timestamps must use the same monotonic clock as Tick. The host owns input and consent.
    public interface ISnapTrigger { bool TryTake(out double anchor, out string phrase); }

    /// <summary>Drive on the main thread; dispose before releasing the borrowed frame history.</summary>
    public sealed class SnitchCam : IDisposable
    {
        readonly ISnapContextProvider context;
        readonly ISnapPublicationStore store;
        readonly SnitchFrames frames;
        readonly SnitchPolaroid feedback;
        readonly ISnapTrigger[] triggers;
        readonly SnapOutcome outcomes;
        Task publishing;
        StripCapture strip;
        byte[] photo;
        SnapContext snap;
        bool disposed;

        public SnitchCam(SnitchFrames frames, ISnapContextProvider context, ISnapPublicationStore store,
            SnapOutcome outcomes, SnitchPolaroid feedback = null, params ISnapTrigger[] triggers) =>
            (this.frames, this.context, this.store, this.outcomes, this.feedback, this.triggers) =
            (frames, context, store, outcomes, feedback, triggers ?? Array.Empty<ISnapTrigger>());

        public void Tick(Camera head, double now)
        {
            if (disposed) return;
            frames.Tick(head, now);
            if (feedback) while (outcomes.TryTake(out var result)) feedback.SetStatus(result.Snap, result.Status);
            if (strip != null)
            {
                strip.Tick(now >= snap.triggerT + SnapStrip.After + 1);
                if (strip.Finished) Publish();
            }
            foreach (var trigger in triggers)
                if (trigger.TryTake(out var anchor, out var phrase)) TrySnap(head, now, anchor, phrase);
        }
        public bool TrySnap(Camera head, double now, double anchor, string phrase = null)
        {
            if (disposed || !head || strip != null || publishing?.IsCompleted == false ||
                double.IsNaN(anchor) || double.IsInfinity(anchor) || anchor > now) return false;
            snap = context.CaptureContext();
            if (!SessionRules.IsId(snap.session)) return false;
            (snap.snap, snap.phrase, snap.triggerT) = ("snap-" + Guid.NewGuid().ToString("N"), phrase, now);
            photo = frames.Capture(anchor, out snap.t, preview => { if (feedback) feedback.Begin(snap.snap, head.transform, preview); });
            if (photo == null) { outcomes.Post(new(snap.session, snap.snap, SnapStatus.Failed)); return false; }
            snap.frameSource = frames.LastCaptureSource;
            strip = new StripCapture(frames, snap.snap, anchor, snap.t);
            return true;
        }
        void Publish()
        {
            var data = snap;
            (data.strip, data.stripMain) = (strip.Entries.ToArray(), strip.MainIndex);
            var files = new Dictionary<string, byte[]>(strip.Files) { [data.snap + ".jpg"] = photo,
                [data.snap + ".json"] = Encoding.UTF8.GetBytes(JsonUtility.ToJson(data)) };
            (strip, photo) = (null, null);
            publishing = Task.Run(() =>
            {
                SnapStatus status;
                try { status = store.Publish(data, files); }
                catch (Exception) { status = SnapStatus.Failed; }
                outcomes.Post(new(data.session, data.snap, status));
            });
        }
        public void Dispose() { disposed = true; if (strip != null) { strip.Cut(); Publish(); } }
    }
}
#endif
