using System;
using UnityEngine;

namespace YetiKit.Playtest
{
    /// <summary>Summary of the finished session.</summary>
    [Serializable]
    public sealed class DoneContext
    {
        public float minutes;
        public long frames;
        public int throws, errors;
        public float handMinutes, controllerMinutes;
        public long lost;      // recorded text lost to disk errors (0: complete)
        public bool recovered; // the app died before the session ended (no end numbers)
    }

    /// <summary>
    /// <c>session.done</c>, written at session end after final metadata.
    /// </summary>
    [Serializable]
    public sealed class DoneMarker
    {
        public const string FileName = "session.done";
        public string session, player, build;
        public DoneContext context = new DoneContext();

        public string ToJson() => JsonUtility.ToJson(this);

        public static DoneMarker Parse(string text)
        {
            try { return string.IsNullOrWhiteSpace(text) ? null : JsonUtility.FromJson<DoneMarker>(text); }
            catch (Exception) { return null; }
        }
    }
}
