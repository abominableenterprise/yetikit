#if UNITY_EDITOR || YETIKIT_DEV
using System;
using UnityEngine;
namespace YetiKit.Playtest
{
    /// <summary>Optional main-thread pixel source. The caller owns the source and the target.</summary>
    public interface IFrameSource : IDisposable
    {
        string Name { get; }
        bool TryCopy(RenderTexture destination);
    }
    public static class FrameSourceSelection
    {
        public const string AppRender = "virtual-head";
        public static bool TryCopy(IFrameSource source, RenderTexture target, out string name)
        {
            try { if (source?.TryCopy(target) == true) { name = source.Name; return true; } }
            catch (Exception) { } // Caller renders the fallback.
            name = AppRender; return false;
        }
    }
}
#endif
