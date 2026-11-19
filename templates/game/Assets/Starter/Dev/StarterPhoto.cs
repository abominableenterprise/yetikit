using System;
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

            var stem = "starter-photo-" + Guid.NewGuid().ToString("N");
            var photo = Path.Combine(directory, stem + ".png");
            var metadata = Path.Combine(directory, stem + ".json");
            try
            {
                var png = Capture(camera);
                FileChunkStore.WriteAtomic(metadata, Encoding.UTF8.GetBytes(JsonUtility.ToJson(context, true)));
                FileChunkStore.WriteAtomic(photo, png);
                return "Photo saved locally.";
            }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
            {
                CleanUp(photo, metadata);
                return "Could not write photo.";
            }
            catch (Exception error) when (error is UnityException || error is InvalidOperationException)
            {
                CleanUp(photo, metadata);
                return "Could not capture photo.";
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
