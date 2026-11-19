using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>Canonical right-glove placement math for runtime grip offsets.</summary>
    public static partial class GripAdjustmentMath
    {
        // The left-hand model mirrors only X. Forward/up survive that reflection.
        public static Pose WorldFrame(Transform root) => new Pose(root.position,
            Quaternion.LookRotation(root.TransformVector(Vector3.forward), root.TransformVector(Vector3.up)));

        public static Pose ForHand(Pose canonical, bool right) => right ? canonical : new Pose(
            new Vector3(-canonical.position.x, canonical.position.y, canonical.position.z),
            new Quaternion(canonical.rotation.x, -canonical.rotation.y, -canonical.rotation.z, canonical.rotation.w));

        public static bool IsIdentity(Pose pose) => pose.position.Equals(Vector3.zero) &&
            (pose.rotation.Equals(Quaternion.identity) || pose.rotation.Equals(new Quaternion(0, 0, 0, -1)));

        public static Pose Apply(Pose held, Pose frame, Vector3 localPivot, Pose canonical, bool right)
        {
            // Preserve authored poses bit-for-bit when no offset is present.
            if (IsIdentity(canonical)) return held;
            var extra = ForHand(canonical, right);
            var turn = frame.rotation * extra.rotation * Quaternion.Inverse(frame.rotation);
            var pivot = held.position + held.rotation * localPivot;
            var rotation = turn * held.rotation;
            return new Pose(pivot + frame.rotation * extra.position - rotation * localPivot, rotation);
        }
    }
}
