namespace YetiKit.Hands
{
    public enum PointPinchResult { None, Teleport, Cancel }

    /// <summary>Pure pinch-and-release selection. Cancellation requires an observed open pinch before rearming.</summary>
    public sealed class PointPinchGesture
    {
        public const float PinchEnter = PinchStrength.Closed; // metres
        public const float PinchRelease = 0.03f;             // metres
        bool released;
        public bool Aiming { get; private set; }
        public bool Pinching { get; private set; }
        public string LastCancel { get; private set; } = "";

        public void Reset()
        {
            Aiming = Pinching = released = false;
            LastCancel = "";
        }

        /// <summary>
        /// Tick with the measured tip <paramref name="gap"/> in metres. Only an observed release over a
        /// currently valid target confirms. An invalid target cancels the selection but leaves the preview active.
        /// </summary>
        public PointPinchResult Tick(bool tracked, bool holding, bool ready, bool near, float gap, bool valid, bool available)
        {
            if (!tracked || !(gap >= 0f) || float.IsInfinity(gap)) return Cancel("lost");
            if (holding || !ready || near || !available)
                return Cancel(holding ? "holding" : !ready ? "pose" : near ? "reach" : "busy");

            Aiming = true;
            if (Pinching)
            {
                if (gap <= PinchRelease) return PointPinchResult.None;
                Pinching = false;
                released = true;
                if (valid) return PointPinchResult.Teleport;
                LastCancel = "no-target";
                return PointPinchResult.Cancel;
            }
            if (gap > PinchRelease) released = true;
            else if (released && gap < PinchEnter)
            {
                Pinching = true;
                released = false;
            }
            return PointPinchResult.None;
        }

        PointPinchResult Cancel(string reason)
        {
            var wasAiming = Aiming;
            Aiming = Pinching = released = false;
            LastCancel = reason;
            return wasAiming ? PointPinchResult.Cancel : PointPinchResult.None;
        }
    }
}
