using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>An aim point for <see cref="ThrowAssist"/>, with its velocity (m/s, world).
    /// <see cref="Known"/> false: the velocity is only a rough guess, never used to lead.</summary>
    public readonly struct ThrowTarget
    {
        public readonly Vector3 Position, Velocity;
        public readonly bool Known;

        public ThrowTarget(Vector3 position, Vector3 velocity, bool known)
        {
            Position = position;
            Velocity = velocity;
            Known = known;
        }
    }

}
