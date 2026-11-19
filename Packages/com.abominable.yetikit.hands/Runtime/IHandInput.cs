using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Which input source drives the hand this frame.</summary>
    public enum HandMode { None, Controller, TrackedHand }

    /// <summary>One side's gameplay input, independent of the active device or any visual.</summary>
    public interface IHandInput
    {
        bool RightHand { get; }
        HandMode Mode { get; }
        bool HandTracked { get; }
        bool Present { get; }
        HandShape Shape { get; }
        float Grip { get; }
        float Trigger { get; }
        /// <summary>Send controller haptics. A tracked hand can play a cue instead and returns false.</summary>
        bool Haptic(float amplitude, float seconds);
    }

    /// <summary>Tracked hand joints, per side (XR Hands on the headset, a fake in tests).</summary>
    public interface IHandTracking
    {
        /// <summary>The side's wrist pose and its <see cref="HandCurls.Points"/> joint positions, in tracking space (the
        /// XR Origin's Camera Offset). The destination must hold all points; false when that hand is not tracked.</summary>
        bool TryGetHand(bool right, Vector3[] points, out Pose wrist);
    }

    /// <summary>XR Hands joint poses for one side (<see cref="XrHandTracking"/>).</summary>
    public interface IHandJointPoses
    {
        /// <summary>Joint poses in XRHandJointID index order (Wrist, Palm, thumb ...), in tracking space.
        /// Fill a nonempty prefix up to <see cref="XrHandTracking.AllJoints"/>; return false if any requested joint is unavailable.</summary>
        bool TryGetJointPoses(bool right, Pose[] poses);
    }
}
