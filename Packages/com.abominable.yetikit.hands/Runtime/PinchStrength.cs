using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// Thumb-index pinch strength from the tracked tips (pure): 1 with the tips at or closer than <see cref="Closed"/>,
    /// 0 at or beyond <see cref="Open"/>, linear between. Reads the <see cref="HandCurls.Points"/> layout (thumb tip at
    /// <see cref="ThumbTip"/>, index tip at <see cref="IndexTip"/>), in metres.
    /// </summary>
    public static class PinchStrength
    {
        public const float Closed = 0.015f, Open = 0.045f; // m between the thumb and index tips
        public const int ThumbTip = HandCurls.PointsPerFinger - 1;
        public const int IndexTip = 2 * HandCurls.PointsPerFinger - 1;

        public static float FromDistance(float metres) => Mathf.Clamp01((Open - metres) / (Open - Closed));

        public static float From(Vector3[] points) => FromDistance(Vector3.Distance(points[ThumbTip], points[IndexTip]));
    }
}
