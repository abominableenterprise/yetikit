using System;
using System.Collections.Generic;
using System.Text;

namespace YetiKit.Playtest
{
    /// <summary>
    /// The recorder's locked line buffer and event counts. The session hands off whole buffers to the pump.
    /// </summary>
    public sealed class FlightLog
    {
        public const int InitialChars = 192 * 1024;

        internal readonly object Gate = new object();
        /// <summary>The lines not yet handed over; write it only under <see cref="Gate"/>.</summary>
        public StringBuilder Buffer { get; private set; }
        readonly int maxBufferedChars;
        LostRecords rejected;
        public long BackpressureDrops { get { lock (Gate) return rejected.Count; } }
        internal LostRecords Rejected => rejected;
        readonly Dictionary<string, int> counts = new Dictionary<string, int>();
        double origin;
        readonly Func<double> clock;
        readonly IEventClassification classification;
        bool accepting = true;

        public FlightLog(Func<double> clock, IEventClassification classification = null, int maxBufferedChars = InitialChars)
        {
            if (maxBufferedChars <= 0 || maxBufferedChars > InitialChars) throw new ArgumentOutOfRangeException(nameof(maxBufferedChars));
            this.maxBufferedChars = maxBufferedChars;
            Buffer = new StringBuilder(maxBufferedChars);
            this.clock = clock ?? throw new ArgumentNullException(nameof(clock));
            this.classification = classification;
            origin = clock();
        }

        /// <summary>Forward a producer's events to this log until the returned handle is disposed.</summary>
        public IDisposable Register(IFlightEventSource source) => FlightEventRegistration.Attach(this, source);

        /// <summary>Seconds since the session started (the <c>t</c> of every line).</summary>
        public double Now => clock() - origin;

        public int Events { get; private set; }
        public int Lines { get; private set; }
        public int Samples { get; private set; }
        public int Throws { get; private set; }
        public int Errors { get; private set; }
        /// <summary>Events other than bookkeeping: what makes a short session worth keeping.</summary>
        public int Meaningful { get; private set; }

        internal void Restart()
        {
            lock (Gate)
            {
                origin = clock();
                counts.Clear();
                Buffer.Clear();
                rejected = default;
                Events = Lines = Meaningful = Samples = Throws = Errors = 0;
                accepting = true;
            }
        }

        internal void Seal() { lock (Gate) accepting = false; }

        void CountLine(string kind, EventClass role)
        {
            Lines++;
            if (role == EventClass.Frame) Samples++;
            if (role != EventClass.Sample && role != EventClass.Frame)
            {
                Events++;
                if (role != EventClass.Bookkeeping) Meaningful++;
                if (role == EventClass.Throw) Throws++;
                if (role == EventClass.Error) Errors++;
                if (counts.TryGetValue(kind, out var n) || counts.Count < 1024) counts[kind] = n + 1;
            }
        }

        /// <summary>Take the buffer and put <paramref name="empty"/> in its place; the caller holds <see cref="Gate"/>.</summary>
        internal StringBuilder Swap(StringBuilder empty)
        {
            var full = Buffer;
            Buffer = empty;
            return full;
        }

        internal void DropBuffer()
        {
            var text = Buffer.ToString();
            foreach (var line in text.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries))
                rejected.Add(LostRecords.TimeOf(line), line.Length + 1);
            Buffer.Clear();
        }

        /// <summary>Append a line. Supply a valid JSON object to merge its fields, or another JSON value
        /// to store under <c>d</c>. Null/empty payload adds no fields.</summary>
        public AppendResult AppendEvent(string kind, string payload) => Append(kind ?? "mark", payload, null);

        internal AppendResult Append(string kind, string payload, EventClass? role)
        {
            lock (Gate)
            {
                if (!accepting) return AppendResult.Sealed;
                var time = Math.Max(0, Now);
                var start = Buffer.Length;
                // Reject oversized inputs before escaping/normalizing them. Escaping grows by at most 6x.
                if ((long)kind.Length + (payload?.Length ?? 0) <= maxBufferedChars)
                {
                    JsonLine.Begin(Buffer, time, kind);
                    AppendData(Buffer, payload);
                    JsonLine.End(Buffer);
                    if (Buffer.Length <= maxBufferedChars)
                    {
                        CountLine(kind, role ?? classification?.Classify(kind) ?? EventClass.Meaningful);
                        return AppendResult.Appended;
                    }
                    Buffer.Length = start;
                }
                rejected.Add(time);
                return AppendResult.BufferFull;
            }
        }

        /// <summary>Merge a JSON object's fields into the open line (else <c>,"d":value</c>).</summary>
        public static void AppendData(StringBuilder sb, string json)
        {
            if (string.IsNullOrEmpty(json)) return;
            var s = json.Trim();
            // In valid JSON raw line breaks are whitespace; keep the handoff whole.
            if (s.IndexOf('\n') >= 0 || s.IndexOf('\r') >= 0)
                s = s.Replace('\r', ' ').Replace('\n', ' ');
            if (s.Length >= 2 && s[0] == '{' && s[s.Length - 1] == '}')
            {
                var inner = s.Substring(1, s.Length - 2).Trim();
                if (inner.Length > 0) sb.Append(',').Append(inner);
                return;
            }
            sb.Append(",\"d\":");
            if (s.Length > 0 && (s[0] == '[' || s[0] == '"' || s[0] == '-' || char.IsDigit(s[0]) || s == "true" || s == "false" || s == "null"))
                sb.Append(s);
            else JsonLine.Str(sb, s);
        }

        /// <summary>How many lines of an event kind this session has.</summary>
        public int Count(string kind)
        {
            lock (Gate) return counts.TryGetValue(kind, out var n) ? n : 0;
        }

        /// <summary>Every event kind and its count, as a JSON object.</summary>
        public void AppendCounts(StringBuilder sb)
        {
            lock (Gate)
            {
                var keys = new List<string>(counts.Keys);
                keys.Sort(System.StringComparer.Ordinal);
                sb.Append('{');
                for (var i = 0; i < keys.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    JsonLine.Str(sb, keys[i]).Append(':');
                    JsonLine.Int(sb, counts[keys[i]]);
                }
                sb.Append('}');
            }
        }
    }

    public enum EventClass { Sample, Bookkeeping, Meaningful, Frame, Throw, Error }

    public interface IEventClassification
    {
        EventClass Classify(string kind);
    }
}
