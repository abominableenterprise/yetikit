#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
namespace YetiKit.Playtest
{
    public interface IStripFrames
    {
        bool TryNewest(out double time);
        void Window(double from, double to, List<double> times); // Ascending, inclusive.
        byte[] Encode(double time, int quality); // Null if unavailable.
        void Hold(double from); // Protect timestamps >= from; +infinity releases.
    }
    [Serializable]
    public struct StripFrame { public string file; public double t, dt; }
    /// <summary>One strip per history, on the main thread. Finish or Cut before starting another.</summary>
    public sealed class StripCapture
    {
        readonly IStripFrames frames;
        readonly string stem;
        readonly List<double> times = new();
        readonly double anchor, mainTime, recorderOffset;
        readonly Dictionary<string, byte[]> files = new();
        readonly List<StripFrame> entries = new();
        public IReadOnlyDictionary<string, byte[]> Files => files;
        public IReadOnlyList<StripFrame> Entries => entries;
        int next = -1;
        public int MainIndex { get; private set; } = -1;
        public bool Finished { get; private set; }
        public StripCapture(IStripFrames frames, string stem, double anchor, double mainTime, double recorderOffset = 0)
        {
            if (double.IsNaN(anchor) || double.IsInfinity(anchor)) throw new ArgumentOutOfRangeException(nameof(anchor));
            (this.frames, this.stem, this.anchor, this.mainTime, this.recorderOffset) = (frames, stem, anchor, mainTime, recorderOffset);
            frames.Hold(anchor - SnapStrip.Before);
        }
        public void Tick(bool closing = false)
        {
            if (Finished) return;
            if (next < 0)
            {
                if (!closing && (!frames.TryNewest(out var newest) || newest < anchor + SnapStrip.After)) return;
                frames.Window(anchor - SnapStrip.Before, anchor + SnapStrip.After, times); next = 0;
            }
            var count = Math.Min(times.Count, SnapStrip.MaxFrames);
            if (next == count) { Cut(); return; }
            var time = times[next];
            var jpeg = frames.Encode(time, SnapStrip.Quality);
            if (jpeg?.Length > 0)
            {
                var file = stem + SnapStrip.Suffix(next) + ".jpg";
                files.Add(file, jpeg);
                if (time == mainTime) MainIndex = entries.Count;
                entries.Add(new StripFrame { file = file, t = Math.Max(0, time + recorderOffset), dt = time - anchor });
            }
            if (++next == count) Cut(); else frames.Hold(times[next]);
        }
        public void Cut() { if (!Finished) { Finished = true; frames.Hold(double.PositiveInfinity); } }
    }
}
#endif
