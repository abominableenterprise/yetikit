using System;
using System.Text;
using UnityEngine;
using YetiKit.Hands;
using YetiKit.Playtest;

namespace YetiKit.Lab
{
    /// <summary>Emits grip snapshots for a consumer that registers this source with its flight log.</summary>
    /// <remarks>
    /// The <c>griplab</c> v1 payload has <c>v</c> (1), <c>prop</c> (catalog ID), <c>side</c> (L or R),
    /// <c>mode</c> (controller or tracked_hand), <c>grip</c> (grip ID), <c>attach</c> (attach in wrist space),
    /// and <c>wrist</c> (wrist in head space). The recorder supplies <c>t</c> and <c>k</c>.
    /// Each pose is [px,py,pz,qx,qy,qz,qw]: translation in meters rounded to 1 mm, then quaternion
    /// components rounded to four decimals. The quaternion maps child axes into the parent frame.
    /// Frames use Unity's left-handed convention (+X right, +Y up, +Z forward) for both hands;
    /// the side describes the input hand and does not mirror the coordinates.
    /// </remarks>
    public sealed class GripLabFlightEventSource : IFlightEventSource
    {
        public event Action<string, string> Event;

        /// <summary>
        /// Record using attach, wrist, and head poses in the same world or tracking frame, with meters and
        /// unit quaternions (no scale). Only controller and tracked-hand snapshots are recorded.
        /// Pass stable IDs, not display names or user-entered text.
        /// </summary>
        public void Record(string propId, bool rightHand, HandMode mode, string gripId, Pose attach, Pose wrist, Pose head)
        {
            var emit = Event;
            if (emit == null) return;
            string modeName;
            switch (mode)
            {
                case HandMode.Controller: modeName = "controller"; break;
                case HandMode.TrackedHand: modeName = "tracked_hand"; break;
                default: return;
            }

            var json = new StringBuilder("{\"v\":1");
            JsonLine.Field(json, "prop", propId);
            JsonLine.Field(json, "side", rightHand ? "R" : "L");
            JsonLine.Field(json, "mode", modeName);
            JsonLine.Field(json, "grip", gripId);
            AppendRelativePose(JsonLine.Key(json, "attach"), attach, wrist);
            AppendRelativePose(JsonLine.Key(json, "wrist"), wrist, head);
            emit("griplab", json.Append('}').ToString());
        }

        static void AppendRelativePose(StringBuilder json, Pose child, Pose parent)
        {
            var inverse = Quaternion.Inverse(parent.rotation);
            JsonLine.Pose7(json, inverse * (child.position - parent.position), inverse * child.rotation);
        }
    }
}
