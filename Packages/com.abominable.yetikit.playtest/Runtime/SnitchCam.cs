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
        public double noteTrimLeadMs, noteTrimTailMs;
    }
    public interface ISnapContextProvider { SnapContext CaptureContext(); }
    /// <summary>Anchor uses the same monotonic clock as Tick. The host owns input and consent.</summary>
    public interface ISnapTrigger { bool TryTake(out double anchor, out string phrase); }

    public sealed class SnitchCam : IDisposable
    {
        public const double DefaultNoteTimeoutSeconds = 30;
        readonly SnitchFrames frames;
        readonly ISnapContextProvider context;
        readonly ISnapPublicationStore store;
        readonly SnapOutcome outcomes;
        readonly SnitchPolaroid feedback;
        readonly double noteTimeoutSeconds;
        Task publishing;
        PendingSnap pending;
        bool disposed;
        bool Busy => disposed || pending != null || strip != null || publishing?.IsCompleted == false;
        StripCapture strip;
        SnapContext snap;
        Dictionary<string, byte[]> files;
        public SnitchCam(SnitchFrames frames, ISnapContextProvider context, ISnapPublicationStore store,
            SnapOutcome outcomes, SnitchPolaroid feedback = null)
            : this(frames, context, store, outcomes, DefaultNoteTimeoutSeconds, feedback) { }

        public SnitchCam(SnitchFrames frames, ISnapContextProvider context, ISnapPublicationStore store,
            SnapOutcome outcomes, double noteTimeoutSeconds, SnitchPolaroid feedback = null)
        {
            if (!(noteTimeoutSeconds > 0) || double.IsInfinity(noteTimeoutSeconds))
                throw new ArgumentOutOfRangeException(nameof(noteTimeoutSeconds));
            (this.frames, this.context, this.store, this.outcomes, this.feedback) = (frames, context, store, outcomes, feedback);
            this.noteTimeoutSeconds = noteTimeoutSeconds;
        }

        public void Tick(Camera head, double now, ISnapTrigger trigger = null)
        {
            if (disposed) return;
            if (pending != null && now >= pending.Deadline) PublishPending(withNote: false);
            frames.Tick(head, now);
            if (feedback) while (outcomes.TryTake(out var result)) feedback.SetStatus(result.Snap, result.Status);
            strip?.Tick(now >= snap.triggerT + SnapStrip.After + 1);
            if (strip?.Finished == true) Publish();
            if (trigger != null && trigger.TryTake(out var anchor, out var phrase)) TrySnap(head, now, anchor, phrase);
        }
        /// <summary>Optional WAV must be fully encoded by the host before handoff; do not mutate it after acceptance.</summary>
        public bool TrySnap(Camera head, double now, double anchor, string phrase = null, byte[] wave = null)
        {
            if (Busy || !head || double.IsNaN(anchor) || double.IsInfinity(anchor) || anchor > now) return false;
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
        /// <summary>Render and persist a still now, without a frame strip. Requires SnapDelivery.
        /// Returns null when busy, unavailable or not staged. Advance Tick with the same clock to enforce expiry.</summary>
        public PendingSnap BeginSnap(Camera head, double now, string phrase = null)
        {
            var deadline = now + noteTimeoutSeconds;
            if (Busy || !head || double.IsNaN(deadline) || double.IsInfinity(deadline) || store is not SnapDelivery delivery) return null;
            var data = context.CaptureContext();
            if (!SessionRules.IsId(data.session)) return null;
            (data.snap, data.phrase, data.triggerT, data.t) = ("snap-" + Guid.NewGuid().ToString("N"), phrase, now, now);
            (data.strip, data.stripMain) = (Array.Empty<StripFrame>(), -1);
            data.noteTrimLeadMs = data.noteTrimTailMs = 0;
            var photo = frames.CaptureNow(head, preview => { if (feedback) feedback.Begin(data.snap, head.transform, preview); });
            var batch = delivery.Stage(data, photo);
            if (batch != null) return pending = new PendingSnap(this, batch, data.snap, deadline);
            outcomes.Post((data.session, data.snap, SnapStatus.Failed));
            return null;
        }

        internal bool PublishPending(bool withNote)
        {
            if (pending == null) return false;
            var handle = pending;
            var note = withNote ? handle.Note : null;
            var (lead, tail) = (handle.NoteTrimLeadMs, handle.NoteTrimTailMs);
            pending = null;
            handle.Close();
            StartPublication(handle.Batch.Context, () => handle.Batch.Publish(note, lead, tail));
            return true;
        }

        internal bool CancelPending()
        {
            if (pending == null || !pending.Batch.Cancel()) return false;
            if (feedback) feedback.Cancel(pending.Id);
            pending.Close();
            pending = null;
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
            StartPublication(data, () => store.Publish(data, batch));
        }
        void StartPublication(SnapContext data, Func<SnapStatus> publish)
        {
            publishing = Task.Run(() =>
            {
                var status = SnapStatus.Failed;
                try { status = publish(); }
                catch (Exception) { /* Publication errors surface as Failed on the main thread. */ }
                outcomes.Post((data.session, data.snap, status));
            });
        }
        /// <summary>On the main thread, stop capture and finish encoding before waiting up to timeoutMs for local publication.
        /// False means the host must defer quit and retry; true means the outcome, if any, has been posted (including failures).</summary>
        public bool TryShutdown(int timeoutMs)
        {
            if (timeoutMs < 0) throw new ArgumentOutOfRangeException(nameof(timeoutMs));
            Dispose();
            return publishing?.Wait(timeoutMs) ?? true;
        }
        /// <summary>Stop capture and start any remaining publication without waiting. Use TryShutdown before controlled quit.</summary>
        public void Dispose()
        {
            disposed = true;
            PublishPending(withNote: false);
            if (strip != null) { while (!strip.Finished) strip.Tick(closing: true); Publish(); }
        }
    }
}
#endif
