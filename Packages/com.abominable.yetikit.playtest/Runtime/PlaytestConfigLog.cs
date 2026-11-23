using System;

namespace YetiKit.Playtest
{
    internal enum PlaytestConfigSource { Default, Persistent, AppPrivate, EditorEnvironment, Custom }

    internal static class PlaytestConfigLog
    {
        internal static string Format(string endpoint, string player, PlaytestConfigSource source)
        {
            // Never echo the raw URI, even if it could not be parsed.
            var endpointField = Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) &&
                (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp) && uri.Host.Length != 0
                ? "endpoint host=" + uri.Host : "endpoint=none";
            var playerTag = UploadValidation.IsSegment(player) ? player : "unknown";
            var sourceLabel = source switch
            {
                PlaytestConfigSource.AppPrivate => "app-private",
                PlaytestConfigSource.EditorEnvironment => "editor-env",
                _ => source.ToString().ToLowerInvariant()
            };
            return $"YetiKitPlaytest: config {endpointField} player={playerTag} source={sourceLabel}";
        }
    }
}
