using System;
using System.Globalization;

namespace YetiKit.Core
{
    /// <summary>
    /// The build time (pure): <see cref="Stamp"/> bakes it as an ISO 8601 UTC timestamp (<c>2026-11-02T03:55:00Z</c>) and
    /// <see cref="Label"/> shows it in a time zone, short (<c>Nov 1, 8:55 PM</c>). Older builds baked only
    /// the UTC day (<c>2026-11-02</c>): that shows as the day alone (<c>Nov 2</c>), never shifted, since its time is unknown.
    /// </summary>
    public static class BuildTime
    {
        static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
        const string Iso = "yyyy-MM-dd'T'HH:mm:ss'Z'", DayOnly = "yyyy-MM-dd";
        const string Clock = "MMM d, h:mm tt", Day = "MMM d";

        /// <summary>Longest <see cref="Label"/> of a parsed value ("Sep 30, 12:59 PM UTC").</summary>
        public const int MaxLabelLength = 20;

        /// <summary>Read a local zone, keeping an unavailable zone distinct from a successfully resolved UTC zone.</summary>
        public static TimeZoneInfo ResolveZone(Func<TimeZoneInfo> read)
        {
            try { return read(); }
            catch (Exception) { return null; }
        }

        /// <summary>The value to bake: <paramref name="utc"/> as ISO 8601 UTC, to the second.</summary>
        public static string Stamp(DateTime utc) => utc.ToUniversalTime().ToString(Iso, Invariant);

        /// <summary>
        /// <paramref name="baked"/> for the header: an ISO timestamp as date and time of day in <paramref name="zone"/>
        /// (null: in UTC, marked "UTC"), an old date-only value as that day, anything else as it is (cut to
        /// <see cref="MaxLabelLength"/>), and nothing (empty) for none.
        /// </summary>
        public static string Label(string baked, TimeZoneInfo zone)
        {
            var s = baked?.Trim() ?? "";
            if (s.Length == 0) return "";
            const DateTimeStyles utcStyle = DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal;
            if (DateTime.TryParseExact(s, Iso, Invariant, utcStyle, out var utc))
                return zone == null
                    ? utc.ToString(Clock, Invariant) + " UTC"
                    : TimeZoneInfo.ConvertTimeFromUtc(utc, zone).ToString(Clock, Invariant);
            if (DateTime.TryParseExact(s, DayOnly, Invariant, DateTimeStyles.None, out var day))
                return day.ToString(Day, Invariant);
            return s.Length > MaxLabelLength ? s.Substring(0, MaxLabelLength) : s;
        }
    }
}
