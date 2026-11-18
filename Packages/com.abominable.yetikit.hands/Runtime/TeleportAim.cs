using System;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using Object = UnityEngine.Object;

namespace YetiKit.Hands
{
    /// <summary>Samples a hand teleport arc using a controller ray's settings and previews its landing.</summary>
    public sealed class TeleportAim
    {
        public const float MinUp = 0.7f;
        public const float UiReach = 0.15f;

        /// <summary>Reports the first custom obstruction on the supplied finite segment, if any.</summary>
        public delegate bool SegmentBlocker(Vector3 from, Vector3 to, out Vector3 hit);
        public SegmentBlocker Blocker { get; set; }
        /// <summary>Optional additional filter on the physics hit of a candidate landing.</summary>
        public Func<RaycastHit, bool> LandingAllowed { get; set; }

        readonly Vector3[] arc = new Vector3[TeleportArc.Segments + 1];
        int drawn, teleportMask;
        RaycastHit landing;
        BaseTeleportationInteractable landingArea;
        Vector3 hitNormal = Vector3.up;
        GameObject detachedReticle;

        public bool HasTarget { get; set; }
        public TeleportRequest Target { get; private set; }

        public void Cast(Vector3 origin, Vector3 normalizedDir, XRRayInteractor controllerRay, string teleportLayerName,
            float? launchSpeed = null)
        {
            var speed = launchSpeed ?? (controllerRay ? controllerRay.velocity : 10f);
            var gravity = controllerRay ? controllerRay.acceleration : 9.8f;
            var mask = controllerRay ? (int)controllerRay.raycastMask : Physics.DefaultRaycastLayers;
            var triggers = controllerRay ? controllerRay.raycastTriggerInteraction : QueryTriggerInteraction.Ignore;
            teleportMask = string.IsNullOrEmpty(teleportLayerName) ? 0 : (int)InteractionLayerMask.GetMask(teleportLayerName);
            TeleportArc.Sample(origin, normalizedDir, speed, gravity, arc);
            HasTarget = false;
            landingArea = null;
            drawn = arc.Length;
            for (var i = 1; i < arc.Length; i++)
            {
                var from = arc[i - 1];
                var step = arc[i] - from;
                var physicsHit = Physics.Raycast(from, step, out var hit, step.magnitude, mask, triggers);
                if (IntersectBlockers(from, physicsHit ? hit.point : arc[i], out var blockerHit))
                {
                    arc[i] = blockerHit;
                    drawn = i + 1;
                    break;
                }
                if (!physicsHit) continue;
                arc[i] = hit.point;
                drawn = i + 1;
                var area = hit.collider.GetComponentInParent<BaseTeleportationInteractable>();
                if (!AllowsLanding(hit, area)) break;

                landing = hit;
                landingArea = area;
                HasTarget = true;
                var orientation = area.matchOrientation;
                hitNormal = orientation == MatchOrientation.TargetUp || orientation == MatchOrientation.TargetUpAndForward
                    ? area.transform.up : hit.normal;
                Target = new TeleportRequest
                {
                    destinationPosition = hit.point,
                    destinationRotation = area.transform.rotation,
                    matchOrientation = orientation,
                };
                break;
            }
        }

        bool AllowsLanding(RaycastHit hit, BaseTeleportationInteractable area)
        {
            var collider = hit.collider;
            return area && area.isActiveAndEnabled && (area.interactionLayers & teleportMask) != 0
                && collider && collider.enabled && collider.gameObject.activeInHierarchy && hit.normal.y >= MinUp
                && !HandUiGuard.Near(hit.point, UiReach) && (LandingAllowed?.Invoke(hit) ?? true);
        }

        bool IntersectBlockers(Vector3 from, Vector3 to, out Vector3 hit)
        {
            var ui = HandUiGuard.Intersect(from, to, out hit);
            if (Blocker == null || !Blocker(from, ui ? hit : to, out var customHit)) return ui;
            hit = customHit;
            return true;
        }

        /// <summary>Checks current UI and policies without recasting physics or changing the frozen arc or request.
        /// A rejected target stays invalid until the next cast.</summary>
        public bool Revalidate()
        {
            if (!HasTarget) return false;
            if (!AllowsLanding(landing, landingArea)) return HasTarget = false;
            for (var i = 1; i < drawn; i++)
                if (IntersectBlockers(arc[i - 1], arc[i], out _)) return HasTarget = false;
            return true;
        }

        public void Show(bool on, LineRenderer line, Gradient validColor, Gradient invalidColor, GameObject reticle, Transform head)
        {
            ShowReticle(on && HasTarget, reticle, head);
            if (!line) return;
            if (line.enabled != on) line.enabled = on;
            if (!on) return;
            line.useWorldSpace = true;
            line.positionCount = drawn;
            line.SetPositions(arc);
            var gradient = HasTarget ? validColor : invalidColor;
            if (gradient != null) line.colorGradient = gradient;
        }

        /// <summary>Destroys the reticle this aim detached, even if the owner's reference has changed.</summary>
        public void DestroyReticle(GameObject reticle = null)
        {
            var detached = detachedReticle;
            detachedReticle = null;
            if (!detached) return;
            if (Application.isPlaying) Object.Destroy(detached);
            else Object.DestroyImmediate(detached);
        }

        void ShowReticle(bool on, GameObject reticle, Transform head)
        {
            if (detachedReticle && detachedReticle != reticle) DestroyReticle();
            if (!reticle) return;
            // Keep the landing pose independent of later tracking updates to the hand root.
            if (on && reticle.transform.parent)
            {
                reticle.transform.SetParent(null, true);
                detachedReticle = reticle;
            }
            if (reticle.activeSelf != on) reticle.SetActive(on);
            if (!on) return;
            var fwd = Vector3.ProjectOnPlane(head ? head.forward : Vector3.forward, hitNormal);
            if (fwd.sqrMagnitude < 1e-6f) fwd = Vector3.ProjectOnPlane(Vector3.forward, hitNormal);
            if (fwd.sqrMagnitude < 1e-6f) fwd = Vector3.right;
            reticle.transform.SetPositionAndRotation(Target.destinationPosition, Quaternion.LookRotation(fwd, hitNormal));
        }
    }
}
