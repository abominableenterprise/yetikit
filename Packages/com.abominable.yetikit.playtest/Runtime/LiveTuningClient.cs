using System;
using System.Threading;
using System.Threading.Tasks;

namespace YetiKit.Playtest
{
    public interface ILiveTuningSource
    {
        string CurrentJson { get; }
        event Action<string> Changed;
    }

    /// <summary>Use from one thread (Unity's main thread in a player). Polling is independent of upload.</summary>
    public sealed class LiveTuningClient : ILiveTuningSource
    {
        readonly IUploadSettings settings;
        readonly IHttpSender sender;
        string url, key, etag;
        bool refreshing;

        public LiveTuningClient(IUploadSettings settings, IHttpSender sender, TimeSpan? pollInterval = null)
        {
            this.settings = settings;
            this.sender = sender ?? throw new ArgumentNullException(nameof(sender));
            PollInterval = pollInterval ?? TimeSpan.FromSeconds(5);
            if (PollInterval.TotalMilliseconds < 1 || PollInterval.TotalMilliseconds > int.MaxValue)
                throw new ArgumentOutOfRangeException(nameof(pollInterval));
        }

        public TimeSpan PollInterval { get; }
        public string CurrentJson { get; private set; }
        public event Action<string> Changed;

        public async Task PollAsync(CancellationToken cancellationToken)
        {
            while (true)
            {
                await RefreshAsync(cancellationToken);
                await Task.Delay(PollInterval, cancellationToken);
            }
        }

        public async Task RefreshAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (refreshing) return;
            refreshing = true;
            try
            {
                var target = TuningUrl();
                var token = target == null ? null : settings.UploadKey;
                if (target != url || token != key) { url = target; key = token; Update(null, null); }
                if (target == null) return;
                var request = new HttpRequest("GET", target);
                request.Headers["X-Upload-Key"] = token;
                if (etag != null) request.Headers["If-None-Match"] = etag;
                HttpResponse response;
                try { response = await sender.SendAsync(request, cancellationToken); }
                catch (Exception) { cancellationToken.ThrowIfCancellationRequested(); return; }
                cancellationToken.ThrowIfCancellationRequested();
                if (target != TuningUrl() || token != settings.UploadKey) { url = key = null; Update(null, null); }
                else if (response?.StatusCode == 200) Update(response.Body, response.ETag);
                else if (response?.StatusCode == 404) Update(null, null);
                // 304 and transient failures leave the cached value intact.
            }
            finally { refreshing = false; }
        }

        string TuningUrl()
        {
            if (!UploadValidation.TryGetEndpoint(settings, out var endpoint)) return null;
            var player = settings.PlayerTag;
            return UploadValidation.IsSegment(player) ? endpoint + "/t/" + player : null;
        }

        void Update(string json, string tag)
        {
            etag = string.IsNullOrEmpty(tag) || tag.Contains("\r") || tag.Contains("\n") ? null : tag;
            if (CurrentJson == json) return;
            CurrentJson = json;
            Changed?.Invoke(json);
        }
    }
}
