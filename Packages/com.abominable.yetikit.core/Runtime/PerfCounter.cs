using Unity.Profiling;

namespace YetiKit.Core
{
    /// <summary>One profiler counter the performance logger reads (the seam: tests use fakes that turn valid late or read 0 on some frames).</summary>
    public interface IPerfCounter
    {
        /// <summary>True once the counter is bound to a real profiler marker or counter.</summary>
        bool Valid { get; }

        /// <summary>How many frame samples the counter holds right now (0 until its first frame has ended).</summary>
        int Count { get; }

        /// <summary>The newest frame sample (0 when there is none).</summary>
        long LastValue { get; }

        /// <summary>The largest of the frame samples the counter holds (its last few frames; 0 when there are none).</summary>
        long MaxValue { get; }

        /// <summary>Clears held frame samples, keeping the same counter bound and collecting new samples.</summary>
        void ResetSamples();

        void Dispose();
    }

    /// <summary>A started <see cref="ProfilerRecorder"/> that keeps its last <c>capacity</c> frame samples.</summary>
    public sealed class ProfilerPerfCounter : IPerfCounter
    {
        ProfilerRecorder recorder;

        public ProfilerPerfCounter(ProfilerCategory category, string name, int capacity = 1) =>
            recorder = ProfilerRecorder.StartNew(category, name, capacity);

        public bool Valid => recorder.Valid;
        public int Count => recorder.Valid ? recorder.Count : 0;
        public long LastValue => recorder.Valid ? recorder.LastValue : 0;

        public long MaxValue
        {
            get
            {
                var n = Count;
                long max = 0;
                for (var i = 0; i < n; i++)
                {
                    var v = recorder.GetSample(i).Value;
                    if (v > max) max = v;
                }
                return max;
            }
        }

        public void ResetSamples()
        {
            if (!recorder.Valid) return;
            recorder.Reset(); // Reset also stops collection; resume the same bound recorder immediately.
            recorder.Start();
        }

        public void Dispose() => recorder.Dispose();
    }
}
