namespace YetiKit.Playtest
{
    /// <summary>
    /// Which Unity log messages become <c>err</c> lines (pure): Error, Exception and Assert only, at most
    /// <see cref="PerSecond"/> per second, the message plus the first <see cref="StackLines"/> stack lines.
    /// </summary>
    public sealed class ErrorGate
    {
        public const int PerSecond = 5, StackLines = 3;
        double windowStart = double.NegativeInfinity;
        int inWindow;

        /// <summary>Messages dropped by the rate limit so far.</summary>
        public int Dropped { get; private set; }

        public static bool Wanted(UnityEngine.LogType type) =>
            type == UnityEngine.LogType.Error || type == UnityEngine.LogType.Exception || type == UnityEngine.LogType.Assert;

        /// <summary>A new session: its clock starts at 0 again.</summary>
        public void Reset()
        {
            windowStart = double.NegativeInfinity;
            inWindow = 0;
            Dropped = 0;
        }

        /// <summary>May a message at <paramref name="now"/> (s) pass?</summary>
        public bool Allow(double now)
        {
            if (now - windowStart >= 1.0)
            {
                windowStart = now;
                inWindow = 0;
            }
            if (inWindow >= PerSecond)
            {
                Dropped++;
                return false;
            }
            inWindow++;
            return true;
        }

        /// <summary>The first <paramref name="lines"/> non-empty lines of a stack trace, '\n'-joined.</summary>
        public static string Trim(string stack, int lines = StackLines)
        {
            if (string.IsNullOrEmpty(stack)) return "";
            var sb = new System.Text.StringBuilder();
            var n = 0;
            foreach (var line in stack.Split('\n'))
            {
                var l = line.TrimEnd('\r');
                if (l.Length == 0) continue;
                if (n++ > 0) sb.Append('\n');
                sb.Append(l);
                if (n >= lines) break;
            }
            return sb.ToString();
        }
    }
}
