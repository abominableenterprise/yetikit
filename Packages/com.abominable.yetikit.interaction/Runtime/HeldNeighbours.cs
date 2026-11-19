using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// The loose props packed in beside a prop when the player grabs it (the other bottles and cans on the cart, the
    /// rubbish in a trash can). The held prop ignores them (Physics.IgnoreCollision) from the grab until it is back on
    /// its normal layer and clear of them, so snapping into the palm and the flick that follows neither knock them
    /// flying nor get the held prop knocked off the hand's line. Props further away still collide, so a throw at a
    /// pile of cans still scatters it. Only touched on grab and while a pair is pending: no per-frame cost otherwise.
    /// </summary>
    public sealed class HeldNeighbours
    {
        public const float Radius = 0.3f;   // m from the grabbed prop's centre of mass
        public const int MaxNeighbours = 16;

        static readonly Collider[] Hits = new Collider[MaxNeighbours * 2];
        readonly List<Collider> ignored = new List<Collider>(MaxNeighbours);
        readonly Collider[] solids;
        readonly Rigidbody body;

        public HeldNeighbours(Rigidbody body, Collider[] solids) { this.body = body; this.solids = solids; }

        public int Count => ignored.Count;
        public IReadOnlyList<Collider> Ignored => ignored;

        /// <summary>The player grabbed the prop: ignore the other grabbable props within <see cref="Radius"/>.</summary>
        public void Grab(Vector3 centre)
        {
            if (solids.Length == 0) return;
            var n = Physics.OverlapSphereNonAlloc(centre, Radius, Hits, Physics.AllLayers, QueryTriggerInteraction.Ignore);
            for (var i = 0; i < n && ignored.Count < MaxNeighbours; i++)
            {
                var c = Hits[i];
                var other = c.attachedRigidbody;
                if (!other || other == body || !other.GetComponent<GrabbableProp>() || ignored.Contains(c)) continue;
                foreach (var solid in solids) HeldCollisionIgnores.Acquire(solid, c);
                ignored.Add(c);
            }
        }

        bool Overlaps(Collider other)
        {
            foreach (var solid in solids)
                if (solid && other && solid.bounds.Intersects(other.bounds)) return true;
            return false;
        }

        /// <summary>
        /// While <paramref name="held"/> (held or in the release grace) every pair stays ignored; after that each pair
        /// is restored once the two no longer overlap, so a prop dropped back among the others never pops out of them.
        /// </summary>
        public void Tick(bool held)
        {
            if (held || ignored.Count == 0) return;
            for (var i = ignored.Count - 1; i >= 0; i--)
            {
                var c = ignored[i];
                if (Overlaps(c)) continue;
                foreach (var solid in solids) HeldCollisionIgnores.Release(solid, c);
                ignored.RemoveAt(i);
            }
        }

        /// <summary>Restore every pair now (a respawn).</summary>
        public void Clear()
        {
            foreach (var c in ignored)
            foreach (var solid in solids) HeldCollisionIgnores.Release(solid, c);
            ignored.Clear();
        }
    }
}
