using System.Text;
using UnityEngine;

namespace YetiKit.Playtest.XR
{
    /// <summary>Formats hand data as a single JSON object without sampling XR state.</summary>
    internal static class FrameFormat
    {
        internal static void AppendMissingHand(StringBuilder frame) => frame.Append("{\"mode\":\"none\"}");

        internal static void AppendHand(StringBuilder frame, string mode, Pose root, float trigger, float grip,
            float pinch, string shape = null, Pose[] joints = null)
        {
            JsonLine.Str(frame.Append("{\"mode\":"), mode);
            JsonLine.Vec3(JsonLine.Key(frame, "p"), root.position, JsonLine.PosDecimals);
            JsonLine.Rot(JsonLine.Key(frame, "q").Append('['), root.rotation).Append(']');
            JsonLine.Field(frame, "trig", trigger, JsonLine.SpeedDecimals);
            JsonLine.Field(frame, "grip", grip, JsonLine.SpeedDecimals);
            JsonLine.Field(frame, "pinch", pinch, JsonLine.SpeedDecimals);
            if (shape != null) JsonLine.Field(frame, "shape", shape);
            if (joints != null) AppendJoints(frame, joints);
            frame.Append('}');
        }

        static void AppendJoints(StringBuilder frame, Pose[] joints)
        {
            // A flat list of position/quaternion tuples, in XR Hands joint index order.
            JsonLine.Key(frame, "j").Append('[');
            for (var i = 0; i < joints.Length; i++)
            {
                if (i != 0) frame.Append(',');
                JsonLine.Pos(frame, joints[i].position).Append(',');
                JsonLine.Rot(frame, joints[i].rotation);
            }
            frame.Append(']');
        }
    }
}
