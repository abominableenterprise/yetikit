using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>
    /// One curl per finger (0 straight, 1 curled). Controller grip curls the middle, ring and little
    /// fingers, and the trigger curls the index. Either input curls the thumb, with both producing
    /// a full fist. <see cref="MiddleOnly"/> is a geometric pose with no assigned action.
    /// </summary>
    public struct FingerCurls
    {
        public const int Thumb = 0, Index = 1, Middle = 2, Ring = 3, Pinky = 4, Fingers = 5;
        public float thumb, index, middle, ring, pinky;

        public float this[int finger]
        {
            get => finger switch { Thumb => thumb, Index => index, Middle => middle, Ring => ring, _ => pinky };
            set
            {
                switch (finger)
                {
                    case Thumb: thumb = value; break;
                    case Index: index = value; break;
                    case Middle: middle = value; break;
                    case Ring: ring = value; break;
                    default: pinky = value; break;
                }
            }
        }

        public const float ThumbRest = 0.8f; // the thumb's curl with only one of grip/trigger held

        public static readonly FingerCurls Open = default;
        public static readonly FingerCurls Point = new FingerCurls { thumb = 0.8f, index = 0f, middle = 1f, ring = 1f, pinky = 1f };
        /// <summary>Middle finger extended, with the thumb and other fingers curled.</summary>
        public static readonly FingerCurls MiddleOnly = new FingerCurls
            { thumb = 1f, index = 1f, middle = 0f, ring = 1f, pinky = 1f };

        /// <summary>The pose for the controller input (grip and trigger 0..1), or the gesture.</summary>
        public static FingerCurls For(float grip, float trigger, bool gesture)
        {
            if (gesture) return MiddleOnly;
            grip = Mathf.Clamp01(grip);
            trigger = Mathf.Clamp01(trigger);
            return new FingerCurls
            {
                // Resting on the controller with either button; folded right across the fingers in a full fist.
                thumb = Mathf.Max(grip, trigger) * ThumbRest + Mathf.Min(grip, trigger) * (1f - ThumbRest),
                index = trigger,
                middle = grip,
                ring = grip,
                pinky = grip,
            };
        }

        /// <summary>
        /// When holding an object, fully curl the grip fingers and suppress the middle-only pose.
        /// </summary>
        public static FingerCurls For(float grip, float trigger, bool gesture, bool holding) =>
            holding ? For(1f, trigger, false) : For(grip, trigger, gesture);

        /// <summary>Is every curl within <paramref name="tolerance"/> of <paramref name="target"/>?</summary>
        public static bool Near(FingerCurls a, FingerCurls target, float tolerance)
        {
            for (var i = 0; i < Fingers; i++) if (Mathf.Abs(a[i] - target[i]) > tolerance) return false;
            return true;
        }

        /// <summary>Move every curl toward <paramref name="target"/> by at most <paramref name="step"/>.</summary>
        public static FingerCurls MoveTowards(FingerCurls from, FingerCurls target, float step)
        {
            var p = from;
            for (var i = 0; i < Fingers; i++) p[i] = Mathf.MoveTowards(from[i], target[i], step);
            return p;
        }
    }
}
