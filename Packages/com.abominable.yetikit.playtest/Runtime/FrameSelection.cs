#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Collections.Generic;
namespace YetiKit.Playtest
{
    public sealed class FrameSelection<T>
    {
        readonly (double time, T frame)[] slots;
        int next;
        public int Count { get; private set; }
        public int Capacity => slots.Length;
        internal T NextFrame => FrameAt(next);
        public FrameSelection(int capacity) => slots = capacity > 0 ? new (double, T)[capacity] : throw new ArgumentOutOfRangeException(nameof(capacity));
        public void Clear() { Array.Clear(slots, 0, Capacity); next = Count = 0; }
        internal T FrameAt(int index) => slots[index].frame;
        public void Add(double timestamp, T frame)
        {
            if (double.IsNaN(timestamp) || double.IsInfinity(timestamp)) throw new ArgumentOutOfRangeException(nameof(timestamp));
            slots[next] = (timestamp, frame); next = (next + 1) % Capacity;
            Count = Math.Min(Count + 1, Capacity);
        }
        (double time, T frame) AtAge(int age) => slots[(next - 1 - age + Capacity) % Capacity];
        public bool TryNewest(out double time) { time = Count == 0 ? 0 : AtAge(0).time; return Count != 0; }
        public bool WouldEvict(double from) => Count == Capacity && slots[next].time >= from;
        // Ties prefer the newer insertion, even for out-of-order timestamps.
        public bool TryClosest(double timestamp, out T frame, out double frameTime)
        {
            frameTime = 0; frame = default;
            if (Count == 0 || double.IsNaN(timestamp) || double.IsInfinity(timestamp)) return false;
            int best = 0;
            for (int age = 1; age < Count; age++)
                if (Math.Abs(AtAge(age).time - timestamp) < Math.Abs(AtAge(best).time - timestamp)) best = age;
            (frameTime, frame) = AtAge(best); return true;
        }
        public bool TryAt(double timestamp, out T frame)
        {
            if (TryClosest(timestamp, out frame, out var time) && time == timestamp) return true;
            frame = default; return false;
        }
        public void Window(double from, double to, List<double> into)
        {
            into.Clear();
            for (int age = 0; age < Count; age++) { var time = AtAge(age).time; if (from <= time && time <= to) into.Add(time); }
            into.Sort();
        }
    }
}
#endif
