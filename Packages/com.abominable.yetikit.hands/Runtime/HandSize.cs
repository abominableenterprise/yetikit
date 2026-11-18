using UnityEngine;
using UnityEngine.XR.Hands;

namespace YetiKit.Hands
{
    /// <summary>Visual-only uniform size calibration. Only accept a reasonably straight middle finger, never a fist's
    /// short wrist-to-tip chord. No bone translations or gameplay measurements are changed.</summary>
    public static class HandSize
    {
        public const float Minimum = 0.85f;
        public const float Maximum = 1.2f;
        public const float StraightDegrees = 25f;
        public const float SmoothingSeconds = 0.25f;

        public static float TargetScale(Pose[] poses, float restLength)
        {
            if (poses == null || restLength <= 0f) return 1f;
            var wrist = poses[XRHandJointID.Wrist.ToIndex()].position;
            var first = XRHandJointID.MiddleProximal.ToIndex();
            var previous = poses[first].position - wrist;
            var length = previous.magnitude;
            for (var j = 0; j < 3; j++)
            {
                var direction = poses[first + j + 1].position - poses[first + j].position;
                if (Vector3.Angle(previous, direction) > StraightDegrees) return float.NaN;
                length += direction.magnitude;
                previous = direction;
            }
            return Mathf.Clamp(length / restLength, Minimum, Maximum);
        }

        public static float Smooth(float current, float target, float dt) => float.IsNaN(target) ? current :
            Mathf.Lerp(current, target, 1f - Mathf.Exp(-Mathf.Max(0f, dt) / SmoothingSeconds));
    }
}
