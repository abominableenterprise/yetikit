using System;
using System.Globalization;

namespace YetiKit.Playtest
{
    /// <summary>
    /// When a recording session starts and ends, and what it is called (pure). A session starts at app start and again
    /// on a resume after more than <see cref="ResumeGapSeconds"/> paused (the headset was off long enough). A session
    /// shorter than <see cref="MinKeepSeconds"/> with no events is deleted.
    /// </summary>
    public static class SessionRules
    {
        public const double ResumeGapSeconds = 5 * 60;
        public const double MinKeepSeconds = 20;
        public const string IdFormat = "yyyyMMdd-HHmmss";

        /// <summary><c>yyyyMMdd-HHmmss-&lt;4 hex&gt;</c> from a UTC time and a random number (its low 16 bits).</summary>
        public static string NewId(DateTime utc, int random) =>
            utc.ToUniversalTime().ToString(IdFormat, CultureInfo.InvariantCulture) + "-" +
            (random & 0xffff).ToString("x4", CultureInfo.InvariantCulture);

        /// <summary>Is <paramref name="id"/> a session id (directory names in the outbox)?</summary>
        public static bool IsId(string id)
        {
            if (id == null || id.Length != IdFormat.Length + 5 || id[IdFormat.Length] != '-') return false;
            if (!DateTime.TryParseExact(id.Substring(0, IdFormat.Length), IdFormat, CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out _)) return false;
            for (var i = IdFormat.Length + 1; i < id.Length; i++)
                if (!Uri.IsHexDigit(id[i]) || char.IsUpper(id[i])) return false;
            return true;
        }

        /// <summary>A resume after <paramref name="pausedSeconds"/> paused starts a new session.</summary>
        public static bool NewSessionOnResume(double pausedSeconds) => pausedSeconds > ResumeGapSeconds;

        /// <summary>A session worth keeping: long enough, or anything happened in it.</summary>
        public static bool Keep(double seconds, int events) => seconds >= MinKeepSeconds || events > 0;
    }
}
