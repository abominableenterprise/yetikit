using System;
using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Prevents contact jitter between velocity-tracked props held at the same time. A newly grabbed prop ignores
    /// colliders of other held props. Collision is restored once either prop is past its release grace period
    /// and their collider bounds no longer overlap.
    /// </summary>
    public sealed class HeldPairs
    {
        static readonly List<HeldPairs> live = new List<HeldPairs>();

        readonly Collider[] own;
        readonly Func<bool> holding, active;
        readonly List<HeldPairs> others = new List<HeldPairs>();

        /// <param name="own">The prop's solid colliders (children included).</param>
        /// <param name="holding">A hand has it now.</param>
        /// <param name="active">Held, or just let go (<see cref="HeldLayer.Active"/>).</param>
        public HeldPairs(Collider[] own, Func<bool> holding, Func<bool> active)
        {
            this.own = own ?? new Collider[0];
            this.holding = holding;
            this.active = active;
        }

        /// <summary>The held props this one ignores since its grab (tests).</summary>
        public int Count => others.Count;

        /// <summary>In play (enabled): a later grab of another prop may pair with it.</summary>
        public void Enable()
        {
            if (!live.Contains(this)) live.Add(this);
        }

        /// <summary>Out of play: restore every pair it is in.</summary>
        public void Disable()
        {
            Clear();
            live.Remove(this);
        }

        /// <summary>The player grabbed this prop: ignore every prop another hand holds right now.</summary>
        public void Grab()
        {
            foreach (var other in live)
            {
                if (other == this || others.Contains(other) || other.others.Contains(this) || !other.holding()) continue;
                Ignore(other, true);
                others.Add(other);
            }
        }

        /// <summary>
        /// While both are held (or in the release grace) a pair stays ignored; after that it is restored once the two
        /// no longer overlap, so a prop dropped against the other never pops out of it.
        /// </summary>
        public void Tick()
        {
            if (others.Count == 0) return;
            for (var i = others.Count - 1; i >= 0; i--)
            {
                var other = others[i];
                if (active() && other.active()) continue;
                if (Overlap(other)) continue;
                Ignore(other, false);
                others.RemoveAt(i);
            }
        }

        /// <summary>Restore every pair involving this prop now (a reset), regardless of which grab started it.</summary>
        public void Clear()
        {
            foreach (var other in others) Ignore(other, false);
            others.Clear();
            foreach (var p in live) p.Drop(this);
        }

        void Drop(HeldPairs other)
        {
            if (!others.Remove(other)) return;
            Ignore(other, false);
        }

        void Ignore(HeldPairs other, bool ignore)
        {
            foreach (var a in own)
            foreach (var b in other.own)
                if (ignore) HeldCollisionIgnores.Acquire(a, b);
                else HeldCollisionIgnores.Release(a, b);
        }

        bool Overlap(HeldPairs other)
        {
            foreach (var a in own)
            foreach (var b in other.own)
                if (a && b && a.enabled && b.enabled && a.bounds.Intersects(b.bounds)) return true;
            return false;
        }

        /// <summary>The solid colliders on <paramref name="body"/> (its own and its children's; triggers left out).</summary>
        public static Collider[] SolidOf(Rigidbody body)
        {
            var list = new List<Collider>();
            if (!body) return list.ToArray();
            foreach (var c in body.GetComponentsInChildren<Collider>(true))
                if (!c.isTrigger && c.attachedRigidbody == body) list.Add(c);
            return list.ToArray();
        }
    }
}
