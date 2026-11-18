using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// Detects a snap-turn gesture: a fist with the thumb extended sideways relative to the head
    /// and away from the fingers. The hand must stay still for <see cref="HoldTime"/> seconds.
    /// A turn repeats only after the pose is released and remade, and no sooner than
    /// <see cref="Cooldown"/> after the last turn. Holding an object prevents turning.
    /// </summary>
    public sealed class HandTurnGesture
    {
        public const float ThumbStraightEnter = HandShapeClassifier.StraightEnter; // thumb curl at or below: straight
        public const float ThumbStraightStay = HandShapeClassifier.StraightStay;
        public const float SidewaysEnter = 0.8f, SidewaysStay = 0.6f; // |cos| between the thumb and the head's right
        public const float ReachEnter = 0.055f, ReachStay = 0.045f; // m from the thumb tip to the index's middle joint:
                                                                     // a thumb resting across a fist is ~2-3 cm
        public const float HoldTime = 0.3f;  // s the pose is held (still) before it turns
        public const float MaxSpeed = 0.6f;  // m/s of the hand: faster restarts the hold
        public const float Cooldown = 0.6f;  // s between turns

        float since = -1f, lastTurn = float.NegativeInfinity;
        bool fired;

        /// <summary>The pose this frame: -1 thumb left, +1 thumb right, 0 none.</summary>
        public int Pose { get; private set; }

        public void Reset()
        {
            Pose = 0;
            since = -1f;
            fired = false;
        }

        /// <summary>One frame. <paramref name="thumbCurl"/> 0..1; <paramref name="sideways"/> = cos between the thumb
        /// and the head's flat right; <paramref name="reach"/> the thumb tip's distance from the index's middle joint (m);
        /// <paramref name="speed"/> the hand's speed in m/s. Not <paramref name="tracked"/> keeps a fired pose's latch (only
        /// a tracked frame without the pose releases it). Returns -1 (turn left) or +1
        /// (turn right) on the frame a turn fires, else 0.</summary>
        public int Tick(bool tracked, bool fist, float thumbCurl, float sideways, float reach, float speed, bool holding, float now)
        {
            if (!tracked)
            {
                // Tracking unavailable is not a release: a pose that already turned keeps its latch until a tracked frame
                // shows the pose left (a one-frame dropout mid-hold must not turn again). An unfired hold starts over.
                if (!fired)
                {
                    Pose = 0;
                    since = -1f;
                }
                return 0;
            }
            var pose = 0;
            if (!holding && fist)
            {
                if (Pose != 0 && thumbCurl <= ThumbStraightStay && sideways * Pose >= SidewaysStay && reach >= ReachStay) pose = Pose;
                else if (thumbCurl <= ThumbStraightEnter && Mathf.Abs(sideways) >= SidewaysEnter && reach >= ReachEnter) pose = sideways > 0f ? 1 : -1;
            }
            if (pose != Pose)
            {
                Pose = pose;
                fired = false;
                since = pose != 0 ? now : -1f;
            }
            if (pose == 0 || fired) return 0;
            if (speed > MaxSpeed)
            {
                since = now;
                return 0;
            }
            if (now - since < HoldTime || now - lastTurn < Cooldown) return 0;
            fired = true;
            lastTurn = now;
            return pose;
        }
    }
}
