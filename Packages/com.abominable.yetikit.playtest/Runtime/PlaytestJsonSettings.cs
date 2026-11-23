using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;

namespace YetiKit.Playtest
{
    public sealed class PlaytestJsonSettings : IUploadSettings
    {
        public const string FileName = "playtest.json";
        public const string EnvEndpoint = "YETIKIT_PLAYTEST_ENDPOINT", EnvKey = "YETIKIT_PLAYTEST_KEY", EnvPlayer = "YETIKIT_PLAYTEST_PLAYER";
        public string Endpoint { get; private set; }
        public string UploadKey { get; private set; }
        public string PlayerTag { get; private set; }
        public bool Enabled => Endpoint != null && UploadKey != null;
        internal PlaytestConfigSource Source { get; private set; }

        [Serializable] sealed class Raw { public string endpoint, uploadKey, player; }

        // On the main thread: external files/playtest/playtest.json, then Android app-private files/playtest.json.
        public static PlaytestJsonSettings LoadDefault()
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            PlaytestEnrollmentStartup.TryInstall();
#endif
            return LoadPaths(DefaultPaths(),
#if UNITY_EDITOR
                Environment.GetEnvironmentVariable
#else
                null
#endif
            );
        }

        internal static string ExternalPath() => Path.Combine(Application.persistentDataPath, "playtest", FileName);

        static IEnumerable<(string Path, PlaytestConfigSource Source)> DefaultPaths()
        {
            yield return (ExternalPath(), PlaytestConfigSource.Persistent);
#if UNITY_ANDROID && !UNITY_EDITOR
            string privateDir = null;
            try
            {
                using var player = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
                using var activity = player.GetStatic<AndroidJavaObject>("currentActivity");
                using var files = activity?.Call<AndroidJavaObject>("getFilesDir");
                privateDir = files?.Call<string>("getAbsolutePath");
            }
            catch (AndroidJavaException) { }
            if (!string.IsNullOrEmpty(privateDir)) yield return (Path.Combine(privateDir, FileName), PlaytestConfigSource.AppPrivate);
#endif
        }

        internal static PlaytestJsonSettings LoadPaths(IEnumerable<(string Path, PlaytestConfigSource Source)> paths,
            Func<string, string> editorEnvironment = null)
        {
            Raw raw = null;
            var source = PlaytestConfigSource.Default;
            foreach (var (path, fileSource) in paths)
            {
                string text;
                try { text = File.ReadAllText(path); }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { continue; }
                try { raw = JsonUtility.FromJson<Raw>(text); }
                catch (ArgumentException) { }
                source = fileSource;
                break; // Readable wins, even if empty or invalid.
            }
            var editorPlayer = editorEnvironment?.Invoke(EnvPlayer)?.Trim();
            var player = string.IsNullOrEmpty(editorPlayer) ? raw?.player?.Trim() : editorPlayer;
            var settings = new PlaytestJsonSettings
            {
                PlayerTag = string.IsNullOrEmpty(player) ? "unknown" : player,
                Source = source
            };
            settings.SetCredentials(raw?.endpoint, raw?.uploadKey);
            if (settings.SetCredentials(editorEnvironment?.Invoke(EnvEndpoint), editorEnvironment?.Invoke(EnvKey)) ||
                (source == PlaytestConfigSource.Default && !string.IsNullOrEmpty(editorPlayer)))
                settings.Source = PlaytestConfigSource.EditorEnvironment;
            return settings;
        }

        internal static bool IsEnrollmentConfig(string text)
        {
            var raw = JsonUtility.FromJson<Raw>(text);
            if (raw == null) return false;
            var endpoint = UploadValidation.ParseUrl(raw.endpoint);
            return endpoint != null && endpoint.Scheme == Uri.UriSchemeHttps && endpoint.AbsolutePath == "/" &&
                UploadValidation.IsValidKey(raw.uploadKey) && UploadValidation.IsSegment(raw.player);
        }

        bool SetCredentials(string endpoint, string key)
        {
            endpoint = UploadValidation.NormalizeEndpoint(endpoint);
            key = key?.Trim();
            if (endpoint == null || !UploadValidation.IsValidKey(key)) return false;
            Endpoint = endpoint;
            UploadKey = key;
            return true;
        }
    }
}
