using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;
using YetiKit.Playtest;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("YetiKit.Starter.HostTests")]

namespace Game.Dev
{
    // An explicit still, not a recording session. Keep it outside the playtest outbox.
    static class StarterPhoto
    {
        const int Width = 768, Height = 480;
        const string Prefix = "starter-photo-", PngSuffix = ".png", JsonSuffix = ".json";

        [Serializable]
        internal struct Context
        {
            public string experiment;
            public float snapTurnDegrees, defaultSnapTurnDegrees;
            public bool hasOverride, tuningPersistenceAvailable;
        }

        internal static string Save(string directory, Camera camera, Context context)
        {
            if (string.IsNullOrEmpty(directory) || (!Directory.Exists(directory) && !File.Exists(directory)))
                return "Photo folder unavailable.";
            if (!camera) return "Photo camera unavailable.";

            try
            {
                SavePair(directory, Capture(camera), context);
                return "Photo saved locally.";
            }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
            {
                return "Could not write photo.";
            }
            catch (Exception error) when (error is UnityException || error is InvalidOperationException)
            {
                return "Could not capture photo.";
            }
        }

        internal static void SavePair(string directory, byte[] png, Context context,
            Action<string, byte[]> writeAtomic = null)
        {
            Reconcile(directory);
            var stem = Path.Combine(directory, Prefix + Guid.NewGuid().ToString("N"));
            var photo = stem + PngSuffix;
            var metadata = stem + JsonSuffix;
            try
            {
                var json = Encoding.UTF8.GetBytes(JsonUtility.ToJson(context, true));
                var write = writeAtomic ?? FileChunkStore.WriteAtomic;
                // The sidecar is the commit marker; never publish it ahead of the image.
                write(photo, png);
                write(metadata, json);
            }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException ||
                                          error is UnityException || error is InvalidOperationException)
            {
                CleanUp(photo, metadata);
                throw;
            }
        }

        // Snap calls from both panels run on Unity's main thread, so no other snap in this player is in flight.
        static void Reconcile(string directory)
        {
            var files = new HashSet<string>(Directory.GetFiles(directory, Prefix + "*"), StringComparer.Ordinal);
            foreach (var path in files)
            {
                var name = Path.GetFileName(path);
                if (!name.StartsWith(Prefix, StringComparison.Ordinal)) continue;
                var endOfStem = name.IndexOf('.', Prefix.Length);
                if (endOfStem != Prefix.Length + 32) continue;
                var id = name.Substring(Prefix.Length, 32);
                if (!Guid.TryParseExact(id, "N", out var guid) || id != guid.ToString("N")) continue;

                var suffix = name.Substring(endOfStem);
                if (suffix == PngSuffix + FileChunkStore.TmpSuffix || suffix == JsonSuffix + FileChunkStore.TmpSuffix)
                    Delete(path);
                else if (suffix == PngSuffix || suffix == JsonSuffix)
                {
                    var counterpart = Path.ChangeExtension(path, suffix == PngSuffix ? JsonSuffix : PngSuffix);
                    if (!files.Contains(counterpart) && !File.Exists(counterpart)) Delete(path);
                }
            }
        }

        static byte[] Capture(Camera camera)
        {
            var previousTarget = camera.targetTexture;
            var previousActive = RenderTexture.active;
            var previousEye = camera.stereoTargetEye;
            var target = RenderTexture.GetTemporary(Width, Height, 24);
            Texture2D image = null;
            try
            {
                image = new Texture2D(Width, Height, TextureFormat.RGB24, false);
                camera.stereoTargetEye = StereoTargetEyeMask.None;
                camera.targetTexture = target;
                camera.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, Width, Height), 0, 0);
                var png = image.EncodeToPNG();
                if (png == null || png.Length == 0) throw new InvalidOperationException("No PNG data.");
                return png;
            }
            finally
            {
                camera.targetTexture = previousTarget;
                camera.stereoTargetEye = previousEye;
                RenderTexture.active = previousActive;
                RenderTexture.ReleaseTemporary(target);
                if (image) UnityEngine.Object.Destroy(image);
            }
        }

        static void CleanUp(params string[] paths)
        {
            foreach (var path in paths)
            {
                Delete(path);
                Delete(path + FileChunkStore.TmpSuffix);
            }
        }

        static void Delete(string path)
        {
            try { File.Delete(path); }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException) { }
        }
    }
}
