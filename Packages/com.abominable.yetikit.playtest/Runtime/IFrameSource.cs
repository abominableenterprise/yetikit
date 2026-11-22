#if UNITY_EDITOR || YETIKIT_DEV
using UnityEngine;
namespace YetiKit.Playtest
{
    public interface IFrameSource { bool TryCopy(RenderTexture destination); }
    public static class FrameSourceSelection
    {
        public static bool TryCopy(IFrameSource source, RenderTexture target) => source?.TryCopy(target) == true;
    }
}
#endif
