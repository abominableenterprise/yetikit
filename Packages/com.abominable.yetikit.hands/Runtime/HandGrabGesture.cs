namespace YetiKit.Hands
{
    /// <summary>
    /// A fist curl or thumb-index pinch can start a grab. Hysteresis prevents jitter from ending it, and
    /// a tracking dropout preserves the grab for <see cref="LostGrace"/> seconds. A new selection requires
    /// tracked input within <see cref="StartWindow"/> seconds of the gesture starting.
    /// The optional trigger is a thumb press on the curled index while grabbing, with
    /// <see cref="PressEnter"/> and <see cref="PressStay"/> thresholds. It arms only after a tracked
    /// thumb lift (press below the stay threshold and no pinch). <see cref="Took"/> checks the thumb
    /// again at selection time so a press that closes during selection cannot trigger until lifted.
    /// A dropout within the grace preserves press and arming state but produces no trigger.
    /// </summary>
    public sealed class HandGrabGesture
    {
        public const float GripEnter = HandShapeClassifier.CurledEnter, GripStay = HandShapeClassifier.CurledStay;
        public const float PinchEnter = 0.8f, PinchStay = 0.5f; // pinch strength: enter at or above, stay at or above
        /// <summary>Thumb press (<see cref="ThumbPress"/>): on at or above <see cref="PressEnter"/> (thumb tip ≤ 2.1 cm from
        /// the index's middle/proximal phalanx), stays on at or above <see cref="PressStay"/> (≤ 3 cm).</summary>
        public const float PressEnter = 0.8f, PressStay = 0.5f;
        public const float LostGrace = 0.15f;  // s an active grab survives lost tracking
        public const float StartWindow = 0.25f; // s after the gesture starts in which it may start a selection

        float lostAt = -1f;
        bool thumbUp;

        public bool Fist { get; private set; }
        public bool Pinching { get; private set; }
        /// <summary>The thumb is pressed onto the curled index (with hysteresis).</summary>
        public bool Pressing { get; private set; }
        /// <summary>The grab is held (fist or pinch, or lost tracking within the grace).</summary>
        public bool Selecting { get; private set; }
        /// <summary>The thumb press counts as the trigger: the thumb has lifted since the grab began (see the class summary).</summary>
        public bool Armed { get; private set; }
        /// <summary>When the current grab gesture started.</summary>
        public float StartedAt { get; private set; } = float.NegativeInfinity;
        /// <summary>The hand trigger, 0..1: the thumb press while holding, armed and pressing, else 0.</summary>
        public float Trigger { get; private set; }
        /// <summary>Tracking is lost and the grab is only kept by the grace.</summary>
        public bool InGrace => lostAt >= 0f && Selecting;

        public void Reset()
        {
            Fist = Pinching = Pressing = Selecting = Armed = thumbUp = false;
            Trigger = 0f;
            lostAt = -1f;
            StartedAt = float.NegativeInfinity;
        }

        /// <summary>May the grab start a new selection at <paramref name="now"/>?</summary>
        public bool CanStart(float now) => Selecting && lostAt < 0f && now - StartedAt <= StartWindow;

        /// <summary>A selection just began: reevaluate arming from the current thumb state so a thumb
        /// that closed during the start window (a pinch closing on contact, a fist wrapping its thumb over) only becomes
        /// the trigger after it lifts once.</summary>
        public void Took()
        {
            if (!Selecting) return;
            Armed = thumbUp;
            Trigger = 0f; // armed: the thumb is up now; not armed: no trigger until it lifts
        }

        /// <summary>One frame: <paramref name="grip"/> 0..1 (fist curl), <paramref name="pinch"/> 0..1 (strength),
        /// <paramref name="press"/> 0..1 (<see cref="ThumbPress"/>).</summary>
        public void Tick(bool tracked, float grip, float pinch, float press, float now)
        {
            // A late reacquisition is a fresh gesture, even without another untracked sample.
            if (lostAt >= 0f && now > lostAt + LostGrace) Reset();
            if (!tracked)
            {
                // No trigger while untracked, but the press keeps its hysteresis through the grace: a thumb held down
                // that re-acquires between PressStay and PressEnter is still down, not a lift that arms the trigger.
                // Arming only ever comes from a tracked thumb-up.
                Trigger = 0f;
                if (!Selecting) { Reset(); return; }
                if (lostAt < 0f) lostAt = now;
                return;
            }
            lostAt = -1f;
            Fist = grip >= (Fist ? GripStay : GripEnter);
            Pinching = pinch >= (Pinching ? PinchStay : PinchEnter);
            Pressing = press >= (Pressing ? PressStay : PressEnter);
            // A partial press may not latch, but it is not a lift.
            thumbUp = !Pinching && press < PressStay;
            var was = Selecting;
            Selecting = Fist || Pinching;
            if (Selecting && !was)
            {
                StartedAt = now;
                Armed = thumbUp;
            }
            else if (Selecting && thumbUp) Armed = true;
            else if (!Selecting) Armed = false;
            Trigger = Selecting && Armed && Pressing ? press : 0f;
        }
    }
}
