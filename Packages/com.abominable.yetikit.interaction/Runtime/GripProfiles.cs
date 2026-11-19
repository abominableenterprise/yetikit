using YetiKit.Hands;
using System;
using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>An optional runtime grip override. The id is caller-owned metadata, not a catalog lookup.
    /// A missing profile uses the prop's existing grip; an empty id still permits a spec override.</summary>
    [Serializable]
    public sealed class GripProfile
    {
        public string id;
        public GripSpec spec;

        public GripProfile(string id, GripSpec spec)
        {
            this.id = id;
            this.spec = spec;
        }
    }

    /// <summary>Per-prop data used by normal gameplay grabs as well as runtime tooling.
    /// None (tracking unavailable) has no override. Profiles may be replaced at runtime;
    /// the next grab reads the new data.</summary>
    [Serializable]
    public sealed class GripProfiles
    {
        // Preserve null in Unity serialization: an absent profile must not become a zero-valued override.
        [SerializeReference] public GripProfile controller;
        [SerializeReference] public GripProfile hand;

        public GripProfile For(HandMode mode) => mode switch
        {
            HandMode.Controller => controller,
            HandMode.TrackedHand => hand,
            _ => null,
        };
    }
}
