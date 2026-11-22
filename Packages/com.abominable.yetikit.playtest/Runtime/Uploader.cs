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

        internal Uploader(Outbox outbox, IUploadSettings settings, IHttpSender sender, double spacing, Func<double> clock)
        {
            this.outbox = outbox;
            this.settings = settings;
            this.sender = sender;
            this.spacing = spacing;
            this.clock = clock;
        }

        /// <summary>Try at most one request; simultaneous ticks and ticks during backoff do no work.</summary>
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
                if (done)
                {
                    request.Body = manifest.ToJson();
                    request.Headers["Idempotency-Key"] = manifest.id;
                }
                else
                {
                    var file = Path.GetFileName(manifest.files[index]);
                    request.FilePath = Path.Combine(dir, file);
                    request.Headers["Content-Type"] = file == FileChunkStore.MetaFile ? "application/json" : "application/gzip";
                }
                HttpResponse response;
                try { response = await sender.SendAsync(request, cancellationToken); }
                catch (Exception) when (!cancellationToken.IsCancellationRequested) { response = null; }
                cancellationToken.ThrowIfCancellationRequested();
                if (response?.Success != true) { Retry(); return; }
                if (done) { outbox.Complete(dir); manifest = null; }
                else index++;
                failures = 0;
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { Retry(); }
            finally { busy = false; }
        }

        void Retry() => nextAt = clock() + Math.Max(spacing, Backoff.Delay(++failures));
    }
}
