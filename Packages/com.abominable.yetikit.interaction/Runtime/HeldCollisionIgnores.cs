using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>Shared collider-pair ignores for grab leases, preserving changes from external owners.</summary>
    public static class HeldCollisionIgnores
    {
        sealed class Lease
        {
            public int Owners;
            public bool RestoreIgnored;
        }

        static readonly Dictionary<(Collider, Collider), Lease> pairs = new Dictionary<(Collider, Collider), Lease>();

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void Reset() => pairs.Clear();

        static (Collider, Collider) Key(Collider a, Collider b) =>
            a.GetEntityId().CompareTo(b.GetEntityId()) < 0 ? (a, b) : (b, a);

        /// <summary>Set the ignore state to restore after all grab leases release, without overriding an active lease.</summary>
        public static void SetExternalIgnore(Collider a, Collider b, bool ignore)
        {
            if (!a || !b) return;
            var leased = pairs.TryGetValue(Key(a, b), out var lease);
            if (leased) lease.RestoreIgnored = ignore;
            Physics.IgnoreCollision(a, b, leased || ignore);
        }

        public static void Acquire(Collider a, Collider b)
        {
            if (!a || !b) return;
            var key = Key(a, b);
            if (!pairs.TryGetValue(key, out var lease))
            {
                lease = new Lease { RestoreIgnored = Physics.GetIgnoreCollision(a, b) };
                pairs.Add(key, lease);
            }
            lease.Owners++;
            Physics.IgnoreCollision(a, b, true);
        }

        public static void Release(Collider a, Collider b)
        {
            // Destroyed Unity objects still identify a lease that must be removed.
            if (ReferenceEquals(a, null) || ReferenceEquals(b, null)) return;
            var key = Key(a, b);
            if (!pairs.TryGetValue(key, out var lease) || --lease.Owners > 0) return;
            pairs.Remove(key);
            if (a && b) Physics.IgnoreCollision(a, b, lease.RestoreIgnored);
        }
    }
}
