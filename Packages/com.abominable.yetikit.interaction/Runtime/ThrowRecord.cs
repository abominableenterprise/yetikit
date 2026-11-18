using System;
using System.Globalization;
using System.Text;
using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Diagnostic data for one release, formatted as a CSV row. Set unknown numeric values to NaN to write
    /// empty fields. Use non-sensitive labels for the prop and source.
    /// </summary>
    public struct ThrowRecord
    {
        public const string Header =
            "time,session_s,prop,speed,dir_x,dir_y,dir_z,controller_speed,source,spin,frame_ms,lever_cm,speed_after,caught,raw_peak,assist,late_ms,early_speed";
        public const string TimeFormat = "yyyy-MM-dd HH:mm:ss.fff";
        public const string NumberFormat = "F2";
        public const char Separator = ',';

        public DateTime Time;          // wall clock at the release (local)
        public float Session;          // s since the app started (Time.realtimeSinceStartup)
        public string Prop;
        public Vector3 Velocity;       // the applied release velocity
        public float ControllerSpeed;  // m/s, the controller's peak (NaN: no controller motion)
        public string Source;          // control path, frame delta or "body"
        public float Spin;             // rad/s
        public float FrameMs;
        public float LeverCm;          // controller to the held centre of mass (NaN: no controller motion)
        public float SpeedAfter;       // m/s, the body's speed at a later measurement (NaN: not measured)
        public bool Caught;            // grabbed again before the later measurement
        public float RawPeak;          // m/s, the fastest raw frame in the release window, before smoothing (NaN: none)
        public bool Assisted;          // aim assist adjusted the launch velocity
        public float LateMs;           // ms spent waiting after release (NaN: not measured)
        public float EarlySpeed;       // m/s before the late-release follow-through (NaN: not measured)
        public Vector3 HandVelocity;   // m/s, the hand's newest sampled velocity at the release (NaN: none); not in the CSV

        /// <summary>Append this throw as one CSV line (ending in '\n'), invariant culture.</summary>
        public void AppendCsv(StringBuilder sb)
        {
            var c = CultureInfo.InvariantCulture;
            var dir = Velocity.sqrMagnitude > 0f ? Velocity.normalized : Vector3.zero;
            sb.Append(Time.ToString(TimeFormat, c)).Append(Separator);
            Number(sb, Session);
            Text(sb, Prop);
            Number(sb, Velocity.magnitude);
            Number(sb, dir.x);
            Number(sb, dir.y);
            Number(sb, dir.z);
            Number(sb, ControllerSpeed);
            Text(sb, Source);
            Number(sb, Spin);
            Number(sb, FrameMs);
            Number(sb, LeverCm);
            Number(sb, SpeedAfter);
            sb.Append(Caught ? '1' : '0').Append(Separator);
            Number(sb, RawPeak);
            sb.Append(Assisted ? '1' : '0').Append(Separator);
            Number(sb, LateMs);
            if (!float.IsNaN(EarlySpeed)) sb.Append(EarlySpeed.ToString(NumberFormat, c));
            sb.Append('\n');
        }

        static void Number(StringBuilder sb, float v)
        {
            if (!float.IsNaN(v)) sb.Append(v.ToString(NumberFormat, CultureInfo.InvariantCulture));
            sb.Append(Separator);
        }

        // Strip CSV delimiters and line breaks so the text stays in a single field.
        static void Text(StringBuilder sb, string s)
        {
            if (s != null)
                foreach (var ch in s)
                    if (ch != Separator && ch != '"' && ch != '\n' && ch != '\r') sb.Append(ch);
            sb.Append(Separator);
        }
    }
}
