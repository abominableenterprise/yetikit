using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Rate-limited distance-grab diagnostics. Writes at most one line per tag and event every
    /// <see cref="Interval"/> seconds, in the Editor and development builds only.
    /// </summary>
    public static class GrabLog
    {
        public const float Interval = 0.5f; // s between two lines of the same tag and event

        static readonly System.Collections.Generic.Dictionary<string, float> last = new System.Collections.Generic.Dictionary<string, float>();

        /// <summary>Lines written (tests).</summary>
        public static int Written { get; private set; }

        /// <summary>Would a line for <paramref name="key"/> at <paramref name="now"/> be written (pure; records it)?</summary>
        public static bool Due(string key, float now)
        {
            if (last.TryGetValue(key, out var at) && now >= at && now - at < Interval) return false;
            last[key] = now;
            return true;
        }

        /// <summary><c>[tag] event: detail</c>, rate limited per tag and event. Pass only non-sensitive labels and details.</summary>
        [System.Diagnostics.Conditional("UNITY_EDITOR"), System.Diagnostics.Conditional("DEVELOPMENT_BUILD")]
        public static void Line(string tag, string evt, string detail)
        {
#if UNITY_EDITOR || DEVELOPMENT_BUILD
            if (!Debug.isDebugBuild) return;
            if (!Due(tag + evt, Time.unscaledTime)) return;
            Written++;
            Debug.Log($"[{tag}] {evt}: {detail}");
#endif
        }
    }
}
