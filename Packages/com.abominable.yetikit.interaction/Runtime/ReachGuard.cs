using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace YetiKit.Interaction
{
    /// <summary>Suppresses teleport while reaching for a nearby interactable or registered world UI.</summary>
    public static class ReachGuard
    {
        static readonly Collider[] Hits = new Collider[16];

        public static bool Near(Vector3 tip, float radius, Transform self = null)
        {
            if (HandUiGuard.Near(tip, radius)) return true;
            var hits = Hits;
            var count = Physics.OverlapSphereNonAlloc(tip, radius, hits, Physics.AllLayers, QueryTriggerInteraction.Collide);
            if (count == hits.Length)
            {
                hits = Physics.OverlapSphere(tip, radius, Physics.AllLayers, QueryTriggerInteraction.Collide);
                count = hits.Length;
            }
            for (var i = 0; i < count; i++)
            {
                if (self && hits[i].transform.IsChildOf(self)) continue;
                var target = hits[i].GetComponentInParent<XRBaseInteractable>();
                if (target && target.isActiveAndEnabled && !(target is BaseTeleportationInteractable)) return true;
            }
            return false;
        }
    }
}
