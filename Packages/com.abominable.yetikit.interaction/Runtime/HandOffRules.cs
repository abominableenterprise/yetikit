using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Pass and toss between hands (pure logic). A prop let go without another hand taking it in the same frame is a
    /// throw: the hand that threw it cannot take it back for <see cref="RegrabGuard"/> s (a soft toss must reach the
    /// other hand, not snap back into the opening one), and for <see cref="CatchWindow"/> s a closing hand within
    /// <see cref="CatchRadius"/> of the prop's path can catch it. A direct pass to the other hand is not a throw.
    /// </summary>
    public static class HandOffRules
    {
        public const float RegrabGuard = 0.2f;   // s the throwing hand cannot re-grab what it threw
        public const float CatchWindow = 0.8f;   // s after a throw in which the catch assist works
        public const float CatchRadius = 0.15f;  // m from the prop's path
        public const float PathBack = 0.1f;      // s of the path behind the prop
        public const float PathAhead = 0.15f;    // s of the path ahead of the prop
        public const float CloseWindow = 0.25f;  // s after the hand starts closing in which it may still catch

        /// <summary>Is <paramref name="who"/> the thrower, inside the guard?</summary>
        public static bool Guarded(object thrower, float thrownAt, object who, float now) =>
            thrower != null && ReferenceEquals(thrower, who) && now - thrownAt < RegrabGuard;

        /// <summary>Still inside the catch window of a throw at <paramref name="thrownAt"/>?</summary>
        public static bool InCatchWindow(float thrownAt, float now) => now >= thrownAt && now - thrownAt <= CatchWindow;

        /// <summary>The distance from <paramref name="hand"/> to the prop's path: the segment from where it was
        /// <see cref="PathBack"/> s ago to where it will be <see cref="PathAhead"/> s from now (straight line).</summary>
        public static float PathDistance(Vector3 hand, Vector3 position, Vector3 velocity)
        {
            var a = position - velocity * PathBack;
            var b = position + velocity * PathAhead;
            var ab = b - a;
            var len2 = ab.sqrMagnitude;
            var t = len2 > 1e-8f ? Mathf.Clamp01(Vector3.Dot(hand - a, ab) / len2) : 0f;
            return Vector3.Distance(hand, a + ab * t);
        }

        /// <summary>A closing hand at <paramref name="hand"/> catches the prop.</summary>
        public static bool Catches(Vector3 hand, Vector3 position, Vector3 velocity) =>
            PathDistance(hand, position, velocity) <= CatchRadius;
    }
}
