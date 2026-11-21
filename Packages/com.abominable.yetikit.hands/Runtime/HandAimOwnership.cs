using System;
using System.Runtime.CompilerServices;
using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>One preview lease per rig. First claim wins unless the requester supplies a preemption policy.</summary>
    public sealed class HandAimOwnership
    {
        static readonly ConditionalWeakTable<Transform, HandAimOwnership> rigs = new();
        object owner;
        Action cancel;

        public static HandAimOwnership For(Transform rig) => rigs.GetValue(rig, _ => new HandAimOwnership());

        public bool IsAvailable(object claimant) => owner == null || ReferenceEquals(owner, claimant);

        public bool Claim(object claimant, Action cancelled, Func<object, bool> canPreempt = null)
        {
            if (claimant == null) throw new ArgumentNullException(nameof(claimant));
            Action previous = null;
            if (owner != null && !ReferenceEquals(owner, claimant))
            {
                var current = owner;
                if (canPreempt?.Invoke(current) != true || !ReferenceEquals(current, owner)) return false;
                previous = cancel;
            }
            // Transfer first so the displaced owner's cleanup cannot release the new lease.
            owner = claimant;
            cancel = cancelled;
            previous?.Invoke();
            return ReferenceEquals(owner, claimant);
        }

        public void Release(object claimant)
        {
            if (!ReferenceEquals(owner, claimant)) return;
            owner = null;
            cancel = null;
        }
    }
}
