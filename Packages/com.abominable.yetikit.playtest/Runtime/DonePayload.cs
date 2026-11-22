using System;
using System.Linq;
using UnityEngine;

namespace YetiKit.Playtest
{
    [Serializable] // File paths in the manifest are bucket-relative.
    internal sealed class DonePayload
    {
        public string id, kind, session, player, build;
        public string[] files;
        public DoneContext context;

        internal static DonePayload Session(DoneMarker marker, string player, string[] names) => new DonePayload
        {
            kind = "session", id = "session-" + marker.session, session = marker.session,
            player = UploadValidation.IsSegment(marker.player) ? marker.player : player, build = marker.build ?? "",
            files = names.Select(name => marker.session + "/" + name).ToArray(), context = marker.context ?? new DoneContext()
        };

        internal string ToJson() => JsonUtility.ToJson(this);
    }
}
