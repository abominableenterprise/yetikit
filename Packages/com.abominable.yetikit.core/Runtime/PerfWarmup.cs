namespace YetiKit.Core
{
    /// <summary>
    /// A performance logger's warm-up gate (pure): it opens after <see cref="Frames"/> frames have run with the scene
    /// loaded, and then stays open. The caller supplies scene readiness; unloaded frames reset the count so the first
    /// sample does not represent a partially loaded scene.
    /// </summary>
    public sealed class PerfWarmup
    {
        public const int DefaultFrames = 60; // ~0.8 s at 72 Hz

        public readonly int Frames;
        int seen;

        public PerfWarmup(int frames = DefaultFrames) => Frames = frames;

        public bool Open => seen >= Frames;

        /// <summary>Call once per frame. True once the gate is open.</summary>
        public bool Tick(bool sceneLoaded)
        {
            if (Open) return true;
            seen = sceneLoaded ? seen + 1 : 0;
            return Open;
        }
    }
}
