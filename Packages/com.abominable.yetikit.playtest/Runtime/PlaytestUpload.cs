using System;
using UnityEngine;

namespace YetiKit.Playtest
{
    public static class PlaytestUpload
    {
        /// <summary>Opt in once per file store, before beginning recording. Reuse the uploader across sessions.</summary>
        public static Uploader Attach(RecordingSession session, IUploadSettings settings, IHttpSender sender = null,
            double spacingSeconds = 1, Func<double> clock = null)
        {
            if (session == null) throw new ArgumentNullException(nameof(session));
            if (session.Begun) throw new InvalidOperationException("Attach before recording starts.");
            if (!(spacingSeconds > 0) || double.IsInfinity(spacingSeconds)) throw new ArgumentOutOfRangeException(nameof(spacingSeconds));
            var outbox = UploadValidation.TryGetEndpoint(settings, out _) ? new Outbox(session.UploadStore) : null;
            outbox?.Recover();
            return new Uploader(outbox, settings, sender ?? new UnityHttpSender(), spacingSeconds,
                clock ?? (() => Time.realtimeSinceStartupAsDouble));
        }
    }
}
