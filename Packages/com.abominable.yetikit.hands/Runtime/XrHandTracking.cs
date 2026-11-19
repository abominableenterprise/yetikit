using System.Collections.Generic;
using UnityEngine;
using UnityEngine.XR.Hands;

namespace YetiKit.Hands
{
    /// <summary>
    /// <see cref="IHandTracking"/> from the running <see cref="XRHandSubsystem"/>.
    /// Joint poses are in tracking space (the XR Origin's Camera Offset). Without a running subsystem, tracking is unavailable.
    /// </summary>
    public sealed class XrHandTracking : IHandTracking, IHandJointPoses
    {
        /// <summary>Every joint XR Hands reports (26: Wrist, Palm, then the fingers), for <see cref="IHandJointPoses"/>.</summary>
        public static readonly int AllJoints = XRHandJointID.EndMarker.ToIndex();

        /// <summary>The joints <see cref="HandCurls"/> reads, in its order (thumb from the wrist, fingers from the metacarpal).</summary>
        public static readonly XRHandJointID[] Joints =
        {
            XRHandJointID.Wrist, XRHandJointID.ThumbMetacarpal, XRHandJointID.ThumbProximal, XRHandJointID.ThumbDistal, XRHandJointID.ThumbTip,
            XRHandJointID.IndexMetacarpal, XRHandJointID.IndexProximal, XRHandJointID.IndexIntermediate, XRHandJointID.IndexDistal, XRHandJointID.IndexTip,
            XRHandJointID.MiddleMetacarpal, XRHandJointID.MiddleProximal, XRHandJointID.MiddleIntermediate, XRHandJointID.MiddleDistal, XRHandJointID.MiddleTip,
            XRHandJointID.RingMetacarpal, XRHandJointID.RingProximal, XRHandJointID.RingIntermediate, XRHandJointID.RingDistal, XRHandJointID.RingTip,
            XRHandJointID.LittleMetacarpal, XRHandJointID.LittleProximal, XRHandJointID.LittleIntermediate, XRHandJointID.LittleDistal, XRHandJointID.LittleTip,
        };

        static readonly List<XRHandSubsystem> Found = new List<XRHandSubsystem>();
        static XRHandSubsystem hooked;
        static float leftDynamicAt = float.NegativeInfinity, rightDynamicAt = float.NegativeInfinity;
        XRHandSubsystem subsystem;

        /// <summary>Raised after the subsystem updates joint poses just before rendering.</summary>
        public static event System.Action BeforeRender;
        int lookedFrame = -1;

        public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
        {
            wrist = default;
            if (points == null || points.Length < Joints.Length) return false;
            var s = Subsystem();
            if (s == null) return false;
            var hand = right ? s.rightHand : s.leftHand;
            if (!hand.isTracked || !hand.GetJoint(XRHandJointID.Wrist).TryGetPose(out wrist)) return false;
            for (var i = 0; i < Joints.Length; i++)
            {
                if (!hand.GetJoint(Joints[i]).TryGetPose(out var p)) return false;
                points[i] = p.position;
            }
            return true;
        }

        public bool TryGetJointPoses(bool right, Pose[] poses)
        {
            if (poses == null || poses.Length == 0) return false;
            var s = Subsystem();
            if (s == null) return false;
            var hand = right ? s.rightHand : s.leftHand;
            if (!hand.isTracked) return false;
            for (var i = 0; i < AllJoints && i < poses.Length; i++)
                if (!hand.GetJoint(XRHandJointIDUtility.FromIndex(i)).TryGetPose(out poses[i])) return false;
            return true;
        }

        XRHandSubsystem Subsystem()
        {
            if (subsystem != null && subsystem.running) return subsystem;
            if (lookedFrame == Time.frameCount) return null; // one search per frame for both hands
            lookedFrame = Time.frameCount;
            SubsystemManager.GetSubsystems(Found);
            subsystem = null;
            foreach (var s in Found) if (s.running) { subsystem = s; break; }
            Hook(subsystem);
            return subsystem;
        }

        // Polling GetJoint can return cached poses. Only a successful Dynamic joint update renews this timestamp.
        internal float LastDynamicSampleAt(bool right) => subsystem != null && subsystem == hooked && subsystem.running
            ? (right ? rightDynamicAt : leftDynamicAt) : float.NegativeInfinity;

        static void Hook(XRHandSubsystem s)
        {
            if (s == null || hooked == s) return;
            if (hooked != null) hooked.updatedHands -= Updated;
            hooked = s;
            leftDynamicAt = rightDynamicAt = float.NegativeInfinity;
            s.updatedHands += Updated;
        }

        static void Updated(XRHandSubsystem s, XRHandSubsystem.UpdateSuccessFlags flags, XRHandSubsystem.UpdateType type)
        {
            if (type == XRHandSubsystem.UpdateType.BeforeRender) RaiseBeforeRender();
            else
            {
                const XRHandSubsystem.UpdateSuccessFlags left = XRHandSubsystem.UpdateSuccessFlags.LeftHandRootPose |
                    XRHandSubsystem.UpdateSuccessFlags.LeftHandJoints;
                const XRHandSubsystem.UpdateSuccessFlags right = XRHandSubsystem.UpdateSuccessFlags.RightHandRootPose |
                    XRHandSubsystem.UpdateSuccessFlags.RightHandJoints;
                leftDynamicAt = (flags & left) == left ? Time.unscaledTime : float.NegativeInfinity;
                rightDynamicAt = (flags & right) == right ? Time.unscaledTime : float.NegativeInfinity;
            }
        }

        /// <summary>Raise <see cref="BeforeRender"/> (the subsystem's BeforeRender update does; tests call it).</summary>
        public static void RaiseBeforeRender() => BeforeRender?.Invoke();
    }
}
