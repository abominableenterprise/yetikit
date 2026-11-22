#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using UnityEngine;
namespace YetiKit.Playtest
{
    [Serializable] public struct SnapContext
    {
        public string session, build, scene, tuning, phrase, snap;
        public Pose pose;
        public double t, triggerT;
        public StripFrame[] strip;
        public int stripMain;
    }
    public interface ISnapContextProvider { SnapContext CaptureContext(); }
    /// <summary>Anchor uses the same monotonic clock as Tick. The host owns input and consent.</summary>
    public interface ISnapTrigger { bool TryTake(out double anchor, out string phrase); }

    public sealed class SnitchCam : IDisposable
    {
        readonly SnitchFrames frames;
        readonly ISnapContextProvider context;
        readonly ISnapPublicationStore store;
        readonly SnapOutcome outcomes;
        readonly SnitchPolaroid feedback;
        Task publishing;
        bool disposed;
        StripCapture strip;
        SnapContext snap;
        Dictionary<string, byte[]> files;
        public SnitchCam(SnitchFrames frames, ISnapContextProvider context, ISnapPublicationStore store,
            SnapOutcome outcomes, SnitchPolaroid feedback = null) =>
            (this.frames, this.context, this.store, this.outcomes, this.feedback) = (frames, context, store, outcomes, feedback);

        public void Tick(Camera head, double now, ISnapTrigger trigger = null)
        {
            if (disposed) return;
            frames.Tick(head, now);
            if (feedback) while (outcomes.TryTake(out var result)) feedback.SetStatus(result.Snap, result.Status);
            strip?.Tick(now >= snap.triggerT + SnapStrip.After + 1);
            if (strip?.Finished == true) Publish();
            if (trigger != null && trigger.TryTake(out var anchor, out var phrase)) TrySnap(head, now, anchor, phrase);
        }
        /// <summary>Optional WAV must be fully encoded by the host before handoff; do not mutate it after acceptance.</summary>
        public bool TrySnap(Camera head, double now, double anchor, string phrase = null, byte[] wave = null)
        {
            if (disposed || !head || strip != null || publishing?.IsCompleted == false ||
                double.IsNaN(anchor) || double.IsInfinity(anchor) || anchor > now) return false;
            snap = context.CaptureContext();
            if (!SessionRules.IsId(snap.session)) return false;
            (snap.snap, snap.phrase, snap.triggerT) = ("snap-" + Guid.NewGuid().ToString("N"), phrase, now);
            var photo = frames.Capture(anchor, out snap.t, preview => { if (feedback) feedback.Begin(snap.snap, head.transform, preview); });
            if (photo == null) { outcomes.Post((snap.session, snap.snap, SnapStatus.Failed)); return false; }
            files = new() { [snap.snap + ".jpg"] = photo };
            if (wave?.Length > 0) files[snap.snap + ".wav"] = wave;
            strip = new StripCapture(frames, snap.snap, anchor, snap.t);
            return true;
        }
        void Publish()
        {
            var data = snap;
            (data.strip, data.stripMain) = (strip.Entries.ToArray(), strip.MainIndex);
            var batch = files;
            foreach (var file in strip.Files) batch.Add(file.Key, file.Value);
            batch[data.snap + ".json"] = System.Text.Encoding.UTF8.GetBytes(JsonUtility.ToJson(data));
            (strip, files) = (null, null);
            publishing = Task.Run(() =>
            {
                var status = SnapStatus.Failed;
                try { status = store.Publish(data, batch); }
                catch (Exception) { /* Publication errors surface as Failed on the main thread. */ }
                outcomes.Post((data.session, data.snap, status));
            });
        }
        public void Dispose() { disposed = true; if (strip != null) { while (!strip.Finished) strip.Tick(closing: true); Publish(); } }
    }
}
#endif
