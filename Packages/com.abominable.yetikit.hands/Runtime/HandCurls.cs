using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// Finger curls from <see cref="Points"/> tracked joint positions in a common coordinate space.
    /// Each finger has five points, thumb first. Thumb: wrist, metacarpal, proximal, distal, tip.
    /// Other fingers: metacarpal, proximal, intermediate, distal, tip (the XRHandJointID order).
    /// Each joint's curl is the bend between its adjacent bones divided by <see cref="FullBend"/>, clamped to 0..1.
    /// </summary>
    public static class HandCurls
    {
        public const int PointsPerFinger = 5;
        public const int Points = FingerCurls.Fingers * PointsPerFinger;

        /// <summary>Degrees of bend that count as fully curled. Fingers: knuckle, middle, last joint.
        /// Thumb: base, knuckle, tip joint.</summary>
        public static readonly Vector3[] FullBend =
        {
            new Vector3(40f, 60f, 70f),
            new Vector3(80f, 95f, 65f),
            new Vector3(80f, 95f, 65f),
            new Vector3(80f, 95f, 65f),
            new Vector3(80f, 95f, 65f),
        };

        /// <summary>Fill <paramref name="into"/> with every joint's curl from <paramref name="points"/>.</summary>
        public static void Measure(Vector3[] points, JointCurls into)
        {
            for (var f = 0; f < FingerCurls.Fingers; f++)
            {
                var o = f * PointsPerFinger;
                for (var j = 0; j < JointCurls.Joints; j++)
                {
                    var before = points[o + j + 1] - points[o + j];
                    var after = points[o + j + 2] - points[o + j + 1];
                    var bend = before.sqrMagnitude < 1e-10f || after.sqrMagnitude < 1e-10f ? 0f : Vector3.Angle(before, after);
                    into[f, j] = Mathf.Clamp01(bend / FullBend[f][j]);
                }
            }
        }

        /// <summary>One curl per finger: the mean of its three joints.</summary>
        public static FingerCurls PerFinger(JointCurls curls)
        {
            var p = new FingerCurls();
            for (var f = 0; f < FingerCurls.Fingers; f++) p[f] = (curls[f, 0] + curls[f, 1] + curls[f, 2]) / 3f;
            return p;
        }
    }
}
