using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>Canonical grip offsets, in metres and a proper (unscaled) glove frame.</summary>
    public static partial class GripAdjustmentMath
    {
        public const float SlideGain = 0.5f;

        public static Pose ToFrame(Pose world, Pose frame)
        {
            var inv = Quaternion.Inverse(frame.rotation);
            return new Pose(inv * (world.position - frame.position), inv * world.rotation);
        }

        /// <summary>Apply an incremental world rotation about the grip centre (not the prop origin).</summary>
        public static Pose RotateWorld(Pose canonical, Pose frame, bool right, Quaternion worldDelta)
        {
            var extra = ForHand(canonical, right);
            extra.rotation = Quaternion.Inverse(frame.rotation) * worldDelta * frame.rotation * extra.rotation;
            return ForHand(extra, right);
        }

        /// <summary>Apply incremental world translation with the fine-adjustment gain.</summary>
        public static Pose SlideWorld(Pose canonical, Pose frame, bool right, Vector3 worldDelta)
        {
            var extra = ForHand(canonical, right);
            extra.position += Quaternion.Inverse(frame.rotation) * worldDelta * SlideGain;
            return ForHand(extra, right);
        }
    }
}
