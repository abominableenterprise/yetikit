namespace YetiKit.Hands
{
    /// <summary>
    /// Aim by pointing the index forward, away from the head, with the thumb raised for
    /// <see cref="ArmTime"/> seconds. Lowering the thumb freezes the aim and confirms on reaching
    /// <see cref="ConfirmDrop"/>. A partial drop beyond <see cref="HalfDropGrace"/> or loss of the point
    /// beyond <see cref="DropGrace"/> cancels the aim. Holding an object or pinching prevents aiming;
    /// a closed pinch while aiming cancels instead of confirming. After a confirm or cancelling pinch,
    /// the thumb must release before a new grab can start.
    /// </summary>
    public sealed class HandTeleportGesture
    {
        public const float ArmTime = 0.3f;     // s of a held forward point, thumb up, before the arc shows
        public const float DropGrace = 0.15f;  // s the aim survives the point dropping (jitter, the index bending)
        public const float ConfirmDrop = ThumbHammer.Enter; // thumb hammer that teleports
        public const float CockedBelow = ThumbHammer.Stay;  // below this the thumb counts as up (cocked) again
        public const float ForwardMin = 0.2f;  // cos between the index and the head's flat forward: at or above aims
        public const float HalfDropGrace = 0.5f; // s a half-dropped thumb (CockedBelow..ConfirmDrop) may hold the aim
        public const float CancelPinch = HandGrabGesture.PinchEnter;  // a pinch this closed while aiming cancels
        public const float ReleasePinch = HandGrabGesture.PinchStay;  // below this the pinch counts as open

        float pointSince = -1f, droppedAt = -1f, droppingSince = -1f;
        bool needRelease;

        /// <summary>The arc is showing.</summary>
        public bool Aiming { get; private set; }
        /// <summary>Aiming and the thumb is on its way down: the arc holds still (the drop must not jerk the aim).</summary>
        public bool Dropping => Aiming && droppingSince >= 0f;
        /// <summary>Aiming, or a confirm's (or a cancelling pinch's) thumb that has not lifted yet: the hand's grab must not
        /// start meanwhile.</summary>
        public bool Busy => Aiming || needRelease;

        public void Reset()
        {
            Aiming = needRelease = false;
            pointSince = droppedAt = droppingSince = -1f;
        }

        /// <summary>One frame. <paramref name="point"/>: the hand makes the Point shape; <paramref name="forward"/>: the
        /// index points away from the head (<see cref="ForwardMin"/>); <paramref name="hammer"/> 0..1 the thumb drop
        /// (<see cref="ThumbHammer"/>); <paramref name="pinch"/> 0..1 the thumb-index pinch (<see cref="PinchStrength"/>).
        /// <paramref name="suppressed"/>: another far interaction owns the hand; cancel the preview but preserve
        /// the release latch, unlike holding an object. True on the frame the thumb drop confirms the aim
        /// (the caller teleports if the arc has a valid target).</summary>
        public bool Tick(bool tracked, bool point, bool forward, float hammer, float pinch, bool holding, float now,
            bool suppressed = false)
        {
            if (!tracked)
            {
                // A dropout ends the aim, not a held pinch/drop. Only tracked input can release the grab block.
                Cancel();
                return false;
            }
            if (holding)
            {
                Reset();
                return false;
            }
            var thumbUp = hammer < CockedBelow && pinch < ReleasePinch;
            if (needRelease)
            {
                if (!thumbUp) return false;
                needRelease = false;
            }
            if (suppressed)
            {
                // A competing interaction cancels the preview, not the release requirement. Also catch
                // a cancelling pinch on the takeover frame, before it can become a fresh grab.
                CancelForTakeover(pinch);
                return false;
            }
            var pose = point && forward;
            if (!Aiming)
            {
                if (!pose || !thumbUp)
                {
                    pointSince = -1f;
                    return false;
                }
                if (pointSince < 0f) pointSince = now;
                if (now - pointSince >= ArmTime)
                {
                    Aiming = true;
                    droppedAt = droppingSince = -1f;
                }
                return false;
            }
            if (pinch >= CancelPinch)
            {
                // A pinch cancels the aim and blocks grabs until the
                // thumb opens, so the pinch that cancelled can't turn into a pinch grab.
                Cancel();
                needRelease = true;
                return false;
            }
            // An existing deadline also applies when this sample starts or completes a thumb drop.
            if ((droppedAt >= 0f && now > droppedAt + DropGrace) ||
                (droppingSince >= 0f && now - droppingSince > HalfDropGrace))
            {
                Cancel();
                return false;
            }
            if (hammer >= ConfirmDrop)
            {
                Aiming = false;
                needRelease = true;
                pointSince = droppingSince = -1f;
                return true;
            }
            if (hammer >= CockedBelow)
            {
                // the thumb is dropping: the arc holds still, and the drop may bend the index out of the Point shape, but
                // only briefly: a half drop held past HalfDropGrace cancels, so a lazy thumb never keeps a frozen aim
                // (and a blocked grab) for a later drop
                droppedAt = -1f;
                if (droppingSince < 0f) droppingSince = now;
                return false;
            }
            droppingSince = -1f;
            if (pose) droppedAt = -1f;
            else if (droppedAt < 0f) droppedAt = now;
            return false;
        }

        internal void CancelForTakeover(float pinch)
        {
            if (Aiming && pinch >= CancelPinch) needRelease = true;
            Cancel();
        }

        void Cancel()
        {
            Aiming = false;
            pointSince = droppedAt = droppingSince = -1f;
        }
    }
}
