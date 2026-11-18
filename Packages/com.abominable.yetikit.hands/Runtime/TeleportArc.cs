using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>A teleport arc from the index tip using projectile motion, sampled at <see cref="Segments"/> + 1 points over <see cref="MaxTime"/> s.</summary>
    public static class TeleportArc
    {
        public const int Segments = 24;
        public const float MaxTime = 2.5f; // s of flight

        /// <summary>Fill <paramref name="into"/> (length <see cref="Segments"/> + 1) with the arc's points.</summary>
        public static void Sample(Vector3 origin, Vector3 direction, float speed, float gravity, Vector3[] into)
        {
            var v = direction.normalized * speed;
            var n = into.Length - 1;
            for (var i = 0; i <= n; i++)
            {
                var t = MaxTime * i / n;
                into[i] = origin + v * t + 0.5f * gravity * t * t * Vector3.down;
            }
        }
    }
}
