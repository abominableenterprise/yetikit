namespace YetiKit.Interaction
{
    /// <summary>
    /// Accepts at most one impact per throw, at or above <see cref="MinSpeed"/> and within
    /// <see cref="ThrownWindow"/> seconds of release. Impacts without a release do not count.
    /// </summary>
    public sealed class PropHitFilter
    {
        public const float MinSpeed = 2.5f;
        public const float ThrownWindow = 3f;

        float thrownAt = float.NegativeInfinity;
        bool spent = true;

        /// <summary>The player let go of the prop at <paramref name="now"/> (a throw or a drop).</summary>
        public void Thrown(float now)
        {
            thrownAt = now;
            spent = false;
        }

        /// <summary>The player picked it up again, or it respawned: nothing in flight any more.</summary>
        public void Reset() => spent = true;

        /// <summary>True for the one impact that counts as a hit; false for everything else.</summary>
        public bool Accept(float speed, float now)
        {
            if (spent || speed < MinSpeed || now - thrownAt > ThrownWindow) return false;
            spent = true;
            return true;
        }
    }
}
