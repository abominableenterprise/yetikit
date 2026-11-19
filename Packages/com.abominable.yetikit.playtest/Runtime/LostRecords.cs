using System;
using System.Globalization;
using System.Text;

namespace YetiKit.Playtest
{
    public struct LostRecords
    {
        public long Count { get; private set; }
        public double? First { get; private set; }
        public double? Last { get; private set; }
        internal long Chars;

        internal void Add(double? time, int chars = 0)
        {
            Count++;
            Chars += chars;
            if (!time.HasValue) return;
            First = Math.Min(First ?? time.Value, time.Value);
            Last = Math.Max(Last ?? time.Value, time.Value);
        }

        internal static double? TimeOf(string line) => line.StartsWith("{\"t\":", StringComparison.Ordinal) &&
            line.IndexOf(',') is var end && end > 5 && double.TryParse(line.Substring(5, end - 5), NumberStyles.Float,
                CultureInfo.InvariantCulture, out var time) ? time : (double?)null;

        internal LostRecords Merge(LostRecords other) => new LostRecords
        {
            Chars = Chars + other.Chars,
            Count = Count + other.Count,
            First = First.HasValue && other.First.HasValue ? Math.Min(First.Value, other.First.Value) : First ?? other.First,
            Last = Last.HasValue && other.Last.HasValue ? Math.Max(Last.Value, other.Last.Value) : Last ?? other.Last,
        };

        internal void Write(StringBuilder sb)
        {
            sb.Append("{\"count\":");
            JsonLine.Int(sb, Count);
            JsonLine.Field(sb, "first", First ?? double.NaN, JsonLine.TimeDecimals);
            JsonLine.Field(sb, "last", Last ?? double.NaN, JsonLine.TimeDecimals);
            JsonLine.Field(sb, "torn", 0);
            sb.Append('}');
        }
    }

    public enum AppendResult { Appended, BufferFull, Sealed }
}
