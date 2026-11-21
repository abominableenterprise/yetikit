using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Point preview with strict timed entry and loose-threshold exit grace.</summary>
    public sealed class PointPinchPose
    {
        public const float MaxPalmUp = 0.45f;
        public const float MaxPalmTowardFace = 0.35f;
        public const float MaxIndexCurl = HandShapeClassifier.CurledEnter;
        public const float EnterDwell = 0.1f;
        public const float ExitDwell = 0.15f;

        float entered = float.NaN, lost = float.NaN;
        bool armed;

        public void Reset()
        {
            entered = lost = float.NaN;
            armed = false;
        }

        /// <summary>Tick with a unit palm normal and head's flat forward direction at time <paramref name="now"/> in seconds.</summary>
        public bool Tick(Vector3 normal, Vector3 forward, FingerCurls curls, float now, bool pinching = false)
        {
            if (!Ready(normal, forward, curls.index)) { Reset(); return false; }
            if (!armed)
            {
                if (!HandShapeClassifier.Holds(HandShape.Point, curls, false))
                { entered = float.NaN; return false; }
                if (float.IsNaN(entered)) entered = now;
                if (now < entered + EnterDwell) return false;
                armed = true;
            }
            var holds = pinching ? CanConfirm(curls) : HandShapeClassifier.Holds(HandShape.Point, curls, true);
            if (holds) lost = float.NaN;
            else
            {
                if (float.IsNaN(lost)) lost = now;
                if (now >= lost + ExitDwell) Reset();
            }
            return armed;
        }

        /// <summary>Current curls allow a release to confirm; preview grace does not relax this check.</summary>
        public static bool CanConfirm(FingerCurls curls) => HandShapeClassifier.MenuPoint(curls, true);

        public static bool Ready(Vector3 normal, Vector3 forward, float indexCurl) =>
            normal.sqrMagnitude > 0.5f && Vector3.Dot(normal, Vector3.up) < MaxPalmUp
            && Vector3.Dot(normal, forward) > -MaxPalmTowardFace && indexCurl < MaxIndexCurl;
    }
}
