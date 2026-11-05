using System;
using System.Linq;
using System.Text;
using UnityEngine;
using UnityEngine.Profiling;

namespace YetiKit.Core
{
    /// <summary>Development-only attribution for a high Texture Memory counter; never enables CPU texture reads.</summary>
    public static class TextureMemoryDiagnostic
    {
        public const long WarningBytes = 256L * 1024 * 1024;

        public static bool ShouldCapture(long bytes, float now, float lastCapture) =>
            bytes > WarningBytes && now - lastCapture >= 60f;

        public static void Capture(long counterBytes)
        {
            if (!Debug.isDebugBuild && !Application.isEditor) return;
            // GetRuntimeMemorySizeLong is Unity's estimate, not Android process PSS or exact GPU residency.
            var rows = Resources.FindObjectsOfTypeAll<Texture>()
                .Select(t => (texture: t, bytes: Profiler.GetRuntimeMemorySizeLong(t)))
                .OrderByDescending(r => r.bytes).ToArray();
            var textures = rows.Where(r => !(r.texture is RenderTexture)).Sum(r => r.bytes);
            var targets = rows.Where(r => r.texture is RenderTexture).Sum(r => r.bytes);
            var sb = new StringBuilder(2048);
            sb.Append("[YetiKit] counterMiB=").Append(MiB(counterBytes))
                .Append(" currentTextureMiB=").Append(MiB((long)Texture.currentTextureMemory))
                .Append(" nonRenderTextureObjectMiB=").Append(MiB(textures))
                .Append(" renderTextureObjectMiB=").Append(MiB(targets))
                .Append(" textureObjects=").Append(rows.Length);
            foreach (var row in rows.Take(12))
            {
                var t = row.texture;
                sb.Append("\n  ").Append(t.name).Append(" ").Append(t.GetType().Name)
                    .Append(" ").Append(t.width).Append("x").Append(t.height)
                    .Append(" mips=").Append(t.mipmapCount).Append(" readable=").Append(t.isReadable)
                    .Append(" format=").Append(t.graphicsFormat).Append(" objectMiB=").Append(MiB(row.bytes));
            }
            Debug.Log(sb.ToString());
        }

        static string MiB(long bytes) => (bytes / 1048576d).ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
    }
}
