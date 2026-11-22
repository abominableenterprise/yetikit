using System;
using System.Text.RegularExpressions;

namespace YetiKit.Playtest
{
    public interface IUploadSettings
    {
        string Endpoint { get; }
        string UploadKey { get; }
        string PlayerTag { get; }
        bool Enabled { get; }
    }

    internal static class UploadValidation
    {
        internal static bool TryGetEndpoint(IUploadSettings settings, out string endpoint, bool requireKey = true)
        {
            endpoint = settings?.Enabled == true && (!requireKey || IsValidKey(settings.UploadKey))
                ? NormalizeEndpoint(settings.Endpoint) : null;
            return endpoint != null;
        }

        internal static bool IsValidKey(string key)
        {
            if (string.IsNullOrWhiteSpace(key)) return false;
            foreach (var c in key) if (c < ' ' || c > '~') return false;
            return true;
        }

        static readonly Regex Segment = new(@"\A[A-Za-z0-9][A-Za-z0-9._-]{0,120}\z");
        internal static bool IsSegment(string value) => value != null && Segment.IsMatch(value);

        internal static string NormalizeEndpoint(string value) => ParseUrl(value?.Trim())?.AbsoluteUri.TrimEnd('/');

        // Cleartext is only for local testing; Unity must also allow insecure HTTP.
        internal static Uri ParseUrl(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Contains("?") || value.Contains("#") || value.Contains("@") ||
                !Uri.TryCreate(value, UriKind.Absolute, out var uri) || !uri.IsWellFormedOriginalString() ||
                uri.Host.Length == 0 || uri.UserInfo.Length != 0) return null;
            return uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback) ? uri : null;
        }
    }
}
