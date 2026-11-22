using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace YetiKit.Playtest
{
    public interface IHttpSender
    {
        Task<HttpResponse> SendAsync(HttpRequest request, CancellationToken cancellationToken);
    }

    public sealed class HttpRequest
    {
        public HttpRequest(string method, string url) { Method = method; Url = url; }
        public string Method { get; }
        public string Url { get; }
        public Dictionary<string, string> Headers { get; } = new(StringComparer.OrdinalIgnoreCase);
        public string FilePath { get; set; }
        public string Body { get; set; }
    }

    public sealed class HttpResponse
    {
        public HttpResponse(long statusCode, string body = null, string etag = null)
        { StatusCode = statusCode; Body = body; ETag = etag; }
        public long StatusCode { get; }
        public string Body { get; }
        public string ETag { get; }
        public bool Success => StatusCode >= 200 && StatusCode < 300;
    }
}
