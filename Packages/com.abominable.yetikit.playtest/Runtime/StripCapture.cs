#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
namespace YetiKit.Playtest
{
    public interface IStripFrames
    {
        bool TryNewest(out double time);
        void Window(double from, double to, List<double> times);
        byte[] Encode(double time, int quality);
        void Hold(double from); // Protect timestamps >= from; infinity releases.
    }
    [Serializable] public struct StripFrame { public string file; public double t, dt; }
    public sealed class StripCapture
    {
        readonly IStripFrames frames;
        readonly string stem;
        readonly double anchor, main;
        readonly List<double> times = new();
        int next = -1;
        public Dictionary<string, byte[]> Files { get; } = new();
        public List<StripFrame> Entries { get; } = new();
        public int MainIndex { get; private set; } = -1;
        public bool Finished { get; private set; }
        public StripCapture(IStripFrames frames, string stem, double anchor, double main)
        {
            (this.frames, this.stem, this.anchor, this.main) = (frames, stem, anchor, main);
            frames.Hold(anchor - SnapStrip.Before);
        }
        public void Tick(bool closing = false)
        {
            if (Finished) return;
            if (next < 0)
            {
                if (!closing && (!frames.TryNewest(out var newest) || newest < anchor + SnapStrip.After)) return;
                frames.Window(anchor - SnapStrip.Before, anchor + SnapStrip.After, times);
                next = 0;
            }
            var count = Math.Min(times.Count, SnapStrip.MaxFrames);
            if (next == count) { Cut(); return; }
            var time = times[next];
            if (frames.Encode(time, 75) is { Length: > 0 } jpeg)
            {
                var file = stem + SnapStrip.Suffix(next) + ".jpg";
                Files.Add(file, jpeg);
                if (time == main) MainIndex = Entries.Count;
                Entries.Add(new StripFrame { file = file, t = time, dt = time - anchor });
            }
            if (++next == count) Cut(); else frames.Hold(times[next]);
        }
        public void Cut() { Finished = true; frames.Hold(double.PositiveInfinity); }
    }
}
#endif
