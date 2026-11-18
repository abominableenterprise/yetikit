namespace YetiKit.Interaction
{
    /// <summary>
    /// Selects a prop's physics layer while held and for <see cref="Grace"/> seconds after release.
    /// Configure the held layer to ignore the holder's colliders without ignoring the environment.
    /// </summary>
    public sealed class HeldLayer
    {
        public const string LayerName = "HeldProp";
        public const float Grace = 0.4f;

        readonly int normal, held;
        bool holding;
        float releasedAt = float.NegativeInfinity;

        public HeldLayer(int normal, int held)
        {
            this.normal = normal;
            this.held = held;
        }

        public void Grab() => holding = true;

        public void Release(float now)
        {
            holding = false;
            releasedAt = now;
        }

        /// <summary>The layer the prop should be on at <paramref name="now"/>.</summary>
        public int Layer(float now) => Active(now) ? held : normal;

        /// <summary>Held, or let go less than <see cref="Grace"/> s ago.</summary>
        public bool Active(float now) => holding || now - releasedAt < Grace;
    }
}
