using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace YetiKit.Interaction
{
    /// <summary>Checks that the downward probe first hits the same teleport interactable as the arc.</summary>
    public static class TeleportGround
    {
        public const float ProbeUp = 2f;
        public const float ProbeDown = 4f;

        public static bool Matches(RaycastHit landing, Transform ignoreRig)
        {
            if (!landing.collider) return false;
            var area = landing.collider.GetComponentInParent<BaseTeleportationInteractable>();
            if (!area || !area.isActiveAndEnabled) return false;

            var origin = landing.point + Vector3.up * ProbeUp;
            return TeleportRaycast.Cast(origin, Vector3.down, ProbeUp + ProbeDown, Physics.DefaultRaycastLayers,
                QueryTriggerInteraction.Ignore, ignoreRig, out var ground)
                && ground.normal.y >= TeleportAim.MinUp
                && ground.collider.GetComponentInParent<BaseTeleportationInteractable>() == area;
        }
    }
}
