using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// Measures the thumb pressing down onto the curled index finger, like
    /// pressing a button on top of the fist. 1 with the thumb tip at or closer than <see cref="Pressed"/> to the
    /// index's proximal phalanx or the near half of its middle phalanx (the side and top of a curled index), 0 at or
    /// beyond <see cref="Up"/> (a thumbs-up is 5-8 cm away), linear between. The far
    /// half of the middle phalanx is left out so a thumb-index pinch (the thumb on the fingertip, 2 cm past the last
    /// joint) reads under <see cref="HandGrabGesture.PressStay"/>. Reads the <see cref="HandCurls.Points"/> layout, in metres. The on/off hysteresis is
    /// <see cref="HandGrabGesture"/>'s (<see cref="HandGrabGesture.PressEnter"/>, <see cref="HandGrabGesture.PressStay"/>).
    /// </summary>
    public static class ThumbPress
    {
        public const float Pressed = 0.015f, Up = 0.045f; // m from the thumb tip to the index's middle/proximal phalanx
        public const int ThumbTip = HandCurls.PointsPerFinger - 1;
        public const int IndexProximal = HandCurls.PointsPerFinger + 1;
        public const int IndexIntermediate = HandCurls.PointsPerFinger + 2;
        public const int IndexDistal = HandCurls.PointsPerFinger + 3;

        public static float FromDistance(float metres) => Mathf.Clamp01((Up - metres) / (Up - Pressed));

        /// <summary>The thumb tip's distance to the index's proximal phalanx and the near half of its middle one (m).</summary>
        public static float Distance(Vector3[] points)
        {
            var tip = points[ThumbTip];
            var middle = points[IndexIntermediate];
            return Mathf.Min(ToSegment(tip, points[IndexProximal], middle),
                ToSegment(tip, middle, Vector3.Lerp(middle, points[IndexDistal], 0.5f)));
        }

        public static float From(Vector3[] points) => FromDistance(Distance(points));

        /// <summary>The distance from a point to the segment a..b (m).</summary>
        internal static float ToSegment(Vector3 p, Vector3 a, Vector3 b)
        {
            var ab = b - a;
            var len = ab.sqrMagnitude;
            var t = len < 1e-10f ? 0f : Mathf.Clamp01(Vector3.Dot(p - a, ab) / len);
            return Vector3.Distance(p, a + ab * t);
        }
    }
}
