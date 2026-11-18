using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// How far the thumb has lowered onto the side of a pointing hand: 0 raised, 1 lowered. The thumb tip's distance to the nearest of the index's proximal phalanx (the side of
    /// the index base) and the middle finger's proximal and intermediate phalanges (the curled middle finger the thumb
    /// lands on): 1 at or closer than <see cref="Down"/>, 0 at or beyond <see cref="Up"/>, linear between.
    /// Real hand geometry: the tracked joints sit on the bones' axes, about 0.8 cm inside the skin, so a thumb resting on
    /// the side of the index base or the middle finger is 1-2 cm from the nearest bone; a cocked thumb (a thumbs-up
    /// above a point) is 5-8 cm away. A pinch (the thumb on the index tip of a straight index) is 4-5 cm from the index
    /// base and reads under <see cref="Stay"/>. Reads the <see cref="HandCurls.Points"/> layout, in metres.
    /// </summary>
    public static class ThumbHammer
    {
        public const float Down = 0.02f, Up = 0.05f; // m from the thumb tip to the nearest measured phalanx
        /// <summary>Hysteresis (like <see cref="HandGrabGesture.PressEnter"/>/<see cref="HandGrabGesture.PressStay"/>):
        /// dropped at or above <see cref="Enter"/> (≤ 2.6 cm), still dropping at or above <see cref="Stay"/> (≤ 3.5 cm);
        /// below <see cref="Stay"/> the hammer is cocked (thumb up).</summary>
        public const float Enter = 0.8f, Stay = 0.5f;
        public const int ThumbTip = HandCurls.PointsPerFinger - 1;
        public const int IndexProximal = HandCurls.PointsPerFinger + 1;
        public const int IndexIntermediate = HandCurls.PointsPerFinger + 2;
        public const int MiddleProximal = 2 * HandCurls.PointsPerFinger + 1;
        public const int MiddleIntermediate = 2 * HandCurls.PointsPerFinger + 2;
        public const int MiddleDistal = 2 * HandCurls.PointsPerFinger + 3;

        public static float FromDistance(float metres) => Mathf.Clamp01((Up - metres) / (Up - Down));

        /// <summary>The thumb tip's distance to the index's proximal phalanx and the middle finger's proximal and
        /// intermediate phalanges, whichever is nearest (m).</summary>
        public static float Distance(Vector3[] points)
        {
            var tip = points[ThumbTip];
            var index = ThumbPress.ToSegment(tip, points[IndexProximal], points[IndexIntermediate]);
            var middle = Mathf.Min(ThumbPress.ToSegment(tip, points[MiddleProximal], points[MiddleIntermediate]),
                ThumbPress.ToSegment(tip, points[MiddleIntermediate], points[MiddleDistal]));
            return Mathf.Min(index, middle);
        }

        public static float From(Vector3[] points) => FromDistance(Distance(points));
    }
}
