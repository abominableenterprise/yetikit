using System;
using UnityEngine;
using YetiKit.Interaction;

namespace Game.Starter
{
    // The sandbox owns its two props and target set; no kit-wide hook is installed.
    public sealed class SandboxBindings : MonoBehaviour, IThrownHitSink
    {
        [SerializeField] BoxCollider recoveryVolume;
        [SerializeField] GrabbableProp[] props;
        [SerializeField] ImpactCue[] targets;

        public void Configure(BoxCollider recovery, GrabbableProp[] roomProps, ImpactCue[] roomTargets)
        {
            recoveryVolume = recovery;
            props = roomProps;
            targets = roomTargets;
        }

        void OnEnable()
        {
            foreach (var prop in props)
            {
                var settings = prop.RespawnSettings;
                settings.FallY = recoveryVolume.bounds.max.y;
                prop.RespawnSettings = settings;
                prop.HitSink = this;
            }
        }

        void OnDisable()
        {
            foreach (var prop in props)
                if (prop && ReferenceEquals(prop.HitSink, this)) prop.HitSink = null;
        }

        public Component ResolveTarget(Collider other) =>
            other && other.TryGetComponent<ImpactCue>(out var cue) && Array.IndexOf(targets, cue) >= 0 ? cue : null;

        public void OnHit(PropHit hit)
        {
            if (hit.Target is ImpactCue cue && cue) cue.Play();
        }
    }
}
