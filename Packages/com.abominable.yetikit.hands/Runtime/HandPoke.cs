namespace YetiKit.Hands
{
    /// <summary>
    /// A tracked fingertip button: a fingertip entering a small sphere presses it once; it must leave the sphere
    /// (by <see cref="ExitMargin"/> past the radius) before it can press again, and no press comes within
    /// <see cref="Cooldown"/> of the last one (an entry inside the cooldown is used up: leave and poke again).
    /// </summary>
    public sealed class HandPoke
    {
        /// <summary>The poking index must be at most this curled (the shape classifier's "stay straight"), so a fist or
        /// a relaxed hand brushing past does not press.</summary>
        public const float IndexStraight = 0.42f;
        /// <summary>m past the radius before the fingertip counts as out again (no chatter on the edge).</summary>
        public const float ExitMargin = 0.01f;

        public readonly float Cooldown;
        float last = float.NegativeInfinity;

        public HandPoke(float cooldown) => Cooldown = cooldown;

        /// <summary>The fingertip is in (pressed and not yet left).</summary>
        public bool Inside { get; private set; }

        /// <summary>One frame: the fingertip's distance to the button centre. True on the frame it presses.</summary>
        public bool Tick(float distance, float radius, float now)
        {
            if (Inside)
            {
                if (distance > radius + ExitMargin) Inside = false;
                return false;
            }
            if (distance > radius) return false;
            Inside = true;
            if (now - last < Cooldown) return false;
            last = now;
            return true;
        }

        /// <summary>No fingertip this frame (not tracked, not straight, no other hand): it counts as out.</summary>
        public void Release() => Inside = false;
    }
}
