using System;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;
using UnityEngine.Networking;

namespace YetiKit.Playtest
{
    public sealed class UnityHttpSender : IHttpSender
    {
        public async Task<HttpResponse> SendAsync(HttpRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await Awaitable.MainThreadAsync();
            cancellationToken.ThrowIfCancellationRequested();
            var url = UploadValidation.ParseUrl(request.Url);
            if (url == null) return new HttpResponse(0);
            try
            {
                using var web = new UnityWebRequest(url.AbsoluteUri, request.Method) { redirectLimit = 0, timeout = 120 };
                web.downloadHandler = new DownloadHandlerBuffer();
                if (request.FilePath != null) web.uploadHandler = new UploadHandlerFile(request.FilePath);
                else if (request.Body != null) web.uploadHandler = new UploadHandlerRaw(Encoding.UTF8.GetBytes(request.Body));
                if (web.uploadHandler != null && !request.Headers.ContainsKey("Content-Type"))
                    web.uploadHandler.contentType = request.FilePath != null ? "application/gzip" : "application/json";
                foreach (var header in request.Headers) web.SetRequestHeader(header.Key, header.Value);
                var operation = web.SendWebRequest();
                // Observe cancellation here so Abort and Dispose always run on Unity's main thread.
                while (!operation.isDone && !cancellationToken.IsCancellationRequested)
                    await Awaitable.NextFrameAsync();
                if (cancellationToken.IsCancellationRequested) web.Abort();
                cancellationToken.ThrowIfCancellationRequested();
                return web.result == UnityWebRequest.Result.ConnectionError || web.result == UnityWebRequest.Result.DataProcessingError
                    ? new HttpResponse(0) : new HttpResponse(web.responseCode, web.downloadHandler.text, web.GetResponseHeader("ETag"));
            }
            // Keep request details out of exceptions surfaced to callers.
            catch (Exception) { cancellationToken.ThrowIfCancellationRequested(); return new HttpResponse(0); }
        }
    }
}
