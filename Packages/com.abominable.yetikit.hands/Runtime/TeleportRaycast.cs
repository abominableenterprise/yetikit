using UnityEngine;

namespace YetiKit.Hands
{
    /// <summary>Raycasts for hand teleport, optionally skipping the rig's own colliders.</summary>
    public static class TeleportRaycast
    {
        public static bool Cast(Vector3 origin, Vector3 direction, float distance, int mask,
            QueryTriggerInteraction triggers, Transform ignoreRig, out RaycastHit hit)
        {
            if (!Physics.Raycast(origin, direction, out hit, distance, mask, triggers)) return false;
            if (!ignoreRig || !hit.collider.transform.IsChildOf(ignoreRig)) return true;

            hit = default;
            foreach (var candidate in Physics.RaycastAll(origin, direction, distance, mask, triggers))
                if (!candidate.collider.transform.IsChildOf(ignoreRig) && (!hit.collider || candidate.distance < hit.distance))
                    hit = candidate;
            return hit.collider;
        }
    }
}
