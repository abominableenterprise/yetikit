namespace YetiKit.Lab
{
    /// <summary>Repeat only: the caller owns the initial click. At most one step per frame, even after a hitch.</summary>
    public sealed class TuningRepeat
    {
        public const float Delay = .4f, Interval = .1f;
        bool active;
        float next;

        public void Begin(float now)
        {
            active = true;
            next = now + Delay;
        }

        public void Cancel() => active = false;

        public bool Tick(bool held, float now)
        {
            if (!held) Cancel();
            if (!active || now < next) return false;
            next = now + Interval;
            return true;
        }
    }
}
