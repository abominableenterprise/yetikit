using System;
using System.Text;
using UnityEngine;
using YetiKit.Hands;

namespace YetiKit.Playtest.XR
{
    /// <summary>Reads both hand sides on the main thread without changing the active input source.</summary>
    internal sealed class HandSampler
    {
        readonly Func<bool, PlayerHand> findHand;
        readonly Pose[] joints = new Pose[XrHandTracking.AllJoints];
        readonly StringBuilder frame = new StringBuilder(2048);

        public HandSampler(Func<bool, PlayerHand> findHand = null)
        {
            this.findHand = findHand ?? PlayerHand.Side;
        }

        /// <summary>
        /// Returns a single JSON object with <c>L</c> and <c>R</c> entries. Unavailable hands
        /// have only a mode; tracked wrists can still be reported without a complete joint set.
        /// </summary>
        public string Sample()
        {
            frame.Clear().Append("{\"L\":");
            AppendHand(findHand(false));
            frame.Append(",\"R\":");
            AppendHand(findHand(true));
            return frame.Append('}').ToString();
        }

        void AppendHand(PlayerHand hand)
        {
            if (!hand || !hand.isActiveAndEnabled)
            {
                FrameFormat.AppendMissingHand(frame);
                return;
            }

            var tracked = hand.HandTracked;
            var hasJoints = tracked && hand.TryJointPoses(joints);
            var controller = hand.controller;
            // An inactive or destroyed controller can retain its last pose; never report it.
            if (!hasJoints && controller && controller.gameObject.activeInHierarchy)
            {
                controller.GetPositionAndRotation(out var position, out var rotation);
                // Only use analog values if the hand is already reporting controller input.
                var controllerMode = hand.Mode == HandMode.Controller;
                FrameFormat.AppendHand(frame, "ctl", new Pose(position, rotation),
                    controllerMode ? hand.Trigger : 0f, controllerMode ? hand.Grip : 0f, 0f);
            }
            else if (tracked)
            {
                FrameFormat.AppendHand(frame, "hand", hand.WristPose, hand.Trigger, hand.Grip, hand.Pinch,
                    hand.Shape.ToString(), hasJoints ? joints : null);
            }
            else FrameFormat.AppendMissingHand(frame);
        }
    }
}
