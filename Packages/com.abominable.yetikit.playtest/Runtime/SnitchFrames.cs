#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
using UnityEngine;
using Object = UnityEngine.Object;
namespace YetiKit.Playtest
{
    public interface IRecorderMetrics { void NoteFrameRender(double milliseconds); }
    /// <summary>Main-thread app-render history. 26 lazy color/depth slots at 512² (about 39 MiB before driver overhead).</summary>
    public sealed class SnitchFrames : IStripFrames, IDisposable
    {
        public const int Size = 512;
        readonly FrameSelection<RenderTexture> history = new(26);
        readonly IRecorderMetrics metrics;
        readonly LayerMask excludedLayers;
        double last = double.NegativeInfinity, hold = double.PositiveInfinity;
        Texture2D pixels;
        Camera copy;
        public SnitchFrames(IRecorderMetrics metrics = null, LayerMask excludedLayers = default) =>
            (this.metrics, this.excludedLayers) = (metrics, excludedLayers);
        public void Tick(Camera head, double now, IFrameSource source = null)
        {
            if (!head || !(now - last >= 0.25) || double.IsInfinity(now) || history.WouldEvict(hold)) return;
            if (!copy) copy = new GameObject("Playtest capture camera") { hideFlags = HideFlags.HideAndDontSave }.AddComponent<Camera>();
            copy.CopyFrom(head); copy.enabled = false; copy.cullingMask &= ~excludedLayers.value;
            copy.transform.SetPositionAndRotation(head.transform.position, head.transform.rotation);
            copy.stereoTargetEye = StereoTargetEyeMask.None;
            var slot = history.NextFrame ?? new RenderTexture(Size, Size, 16, RenderTextureFormat.ARGB32);
            var active = RenderTexture.active;
            var start = Time.realtimeSinceStartupAsDouble;
            try { if (!FrameSourceSelection.TryCopy(source, slot)) { copy.targetTexture = slot; copy.Render(); } }
            catch { if (slot != history.NextFrame) Kill(slot); throw; }
            finally { copy.targetTexture = null; RenderTexture.active = active; }
            history.Add(now, slot); last = now;
            metrics?.NoteFrameRender((Time.realtimeSinceStartupAsDouble - start) * 1000);
        }
        public byte[] Capture(double at, out double time, Action<Texture> preview = null)
        {
            var jpeg = history.TryClosest(at, out var frame, out time) ? ReadJpeg(frame, 85) : null;
            if (jpeg == null) time = double.NaN; else preview?.Invoke(frame);
            return jpeg;
        }
        bool IStripFrames.TryNewest(out double time) => history.TryNewest(out time);
        void IStripFrames.Window(double from, double to, List<double> times) => history.Window(from, to, times);
        void IStripFrames.Hold(double from) => hold = from;
        public byte[] Encode(double time, int quality) => history.TryAt(time, out var frame) ? ReadJpeg(frame, quality) : null;
        byte[] ReadJpeg(RenderTexture frame, int quality)
        {
            if (!frame.IsCreated()) return null;
            var active = RenderTexture.active;
            try
            {
                pixels ??= new Texture2D(Size, Size, TextureFormat.RGB24, false);
                RenderTexture.active = frame;
                pixels.ReadPixels(new Rect(0, 0, Size, Size), 0, 0, false);
                return pixels.EncodeToJPG(quality);
            }
            catch (UnityException) { return null; }
            finally { RenderTexture.active = active; }
        }
        public void Dispose()
        {
            last = double.PositiveInfinity;
            history.Clear(slot => { slot.Release(); Kill(slot); }); Kill(pixels); if (copy) Kill(copy.gameObject);
            pixels = null; copy = null;
        }
        static void Kill(Object obj) { if (!obj) return; if (Application.isPlaying) Object.Destroy(obj); else Object.DestroyImmediate(obj); }
    }
}
#endif
