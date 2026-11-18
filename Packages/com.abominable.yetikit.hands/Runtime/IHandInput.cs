using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Which input source drives the hand this frame.</summary>
    public enum HandMode { None, Controller, TrackedHand }

    /// <summary>Tracked hand joints, per side (XR Hands on the headset, a fake in tests).</summary>
    public interface IHandTracking
    {
        /// <summary>The side's wrist pose and its <see cref="HandCurls.Points"/> joint positions, in tracking space (the
        /// XR Origin's Camera Offset); false when that hand is not tracked.</summary>
        bool TryGetHand(bool right, Vector3[] points, out Pose wrist);
    }

    /// <summary>XR Hands joint poses for one side (<see cref="XrHandTracking"/>).</summary>
    public interface IHandJointPoses
    {
        /// <summary>The <see cref="XrHandTracking.AllJoints"/> poses in XRHandJointID index order (Wrist, Palm, thumb ...),
        /// in tracking space; false when that hand is not tracked.</summary>
        bool TryGetJointPoses(bool right, Pose[] poses);
    }
}
