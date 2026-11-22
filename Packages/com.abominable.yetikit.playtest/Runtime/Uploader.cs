using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using YetiKit.Core;

namespace YetiKit.Playtest
{
    /// <summary>Drive from the consumer's main-thread update, using unscaled monotonic seconds.</summary>
    public sealed class Uploader
    {
        readonly Outbox outbox;
        readonly IUploadSettings settings;
        readonly IHttpSender sender;
        readonly double spacing;
        readonly Func<double> clock;
        double nextAt;
        int failures, index;
        bool busy;
        string dir, destination;
        DonePayload manifest;
#if UNITY_EDITOR || YETIKIT_DEV
        public SnapOutcome SnapOutcomes { get; set; }

        void ReportSnap(SnapStatus status)
        {
            if (SnapDelivery.Split(dir, out var session, out var stem)) SnapOutcomes?.Post(new(session, stem, status));
        }
#endif

        internal Uploader(Outbox outbox, IUploadSettings settings, IHttpSender sender, double spacing, Func<double> clock) =>
            (this.outbox, this.settings, this.sender, this.spacing, this.clock) = (outbox, settings, sender, spacing, clock);

        public async Task TickAsync(CancellationToken cancellationToken = default)
        {
            var now = clock();
            if (outbox == null || busy || now < nextAt || !UploadValidation.TryGetEndpoint(settings, out var endpoint) ||
                !UploadValidation.IsSegment(settings.PlayerTag)) return;
            cancellationToken.ThrowIfCancellationRequested();
            busy = true;
            nextAt = now + spacing;
            try
            {
                if (manifest == null || endpoint != destination || !Directory.Exists(dir))
                {
                    (dir, manifest) = outbox.Next(settings.PlayerTag);
                    destination = endpoint;
                    index = 0;
                }
                if (manifest == null) return;
                var done = index == manifest.files.Length;
                var request = new HttpRequest(done ? "POST" : "PUT", endpoint + (done ? "/done" : "/u/" + manifest.files[index]));
                request.Headers["X-Upload-Key"] = settings.UploadKey;
                request.Headers["Content-Type"] = "application/json";
                if (done)
                {
                    request.Body = manifest.ToJson();
                    request.Headers["Idempotency-Key"] = manifest.id;
                }
                else
                {
                    var file = Path.GetFileName(manifest.files[index]);
                    request.FilePath = Path.Combine(dir, file);
                    request.Headers["Content-Type"] = Path.GetExtension(file) switch
                    {
                        ".jpg" => "image/jpeg", ".wav" => "audio/wav", ".gz" => "application/gzip", _ => "application/json"
                    };
                }
                HttpResponse response;
                try { response = await sender.SendAsync(request, cancellationToken); }
                catch (Exception) when (!cancellationToken.IsCancellationRequested) { response = null; }
                cancellationToken.ThrowIfCancellationRequested();
                // Only per-request validation failures; auth, routing, throttling and server errors still retry.
                if (response?.StatusCode is 400 or 413 or 415 or 422)
                {
                    outbox.Reject(dir);
#if UNITY_EDITOR || YETIKIT_DEV
                    ReportSnap(SnapStatus.Failed);
#endif
                    manifest = null;
                    failures = 0;
                    return;
                }
                if (response?.Success != true) { Retry(); return; }
                if (done)
                {
                    outbox.Complete(dir);
#if UNITY_EDITOR || YETIKIT_DEV
                    ReportSnap(SnapStatus.Sent);
#endif
                    manifest = null;
                }
                else index++;
                failures = 0;
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { Retry(); }
            finally { busy = false; }
        }

        void Retry() => nextAt = clock() + Math.Max(spacing, Backoff.Delay(++failures));
    }
}
