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
        public const float DefaultLaunchSpeed = 10f;
        public const float DefaultGravity = 9.8f;

        /// <summary>Reports the first custom obstruction on the supplied finite segment, if any.</summary>
        public delegate bool SegmentBlocker(Vector3 from, Vector3 to, out Vector3 hit);
        public SegmentBlocker Blocker { get; set; }
        /// <summary>Optional additional filter on the physics hit of a candidate landing.</summary>
        public Func<RaycastHit, bool> LandingAllowed { get; set; }

        readonly Vector3[] arc = new Vector3[TeleportArc.Segments + 1];
        int drawn, teleportMask;
        RaycastHit landing;
        BaseTeleportationInteractable landingArea;
        GameObject detachedReticle;

        /// <summary>Use the hit point on any teleport interactable, including anchors, rather than only areas.</summary>
        public bool AllowAnchorSurfaces { get; set; }
        public bool HasTarget { get; set; }
        public TeleportRequest Target { get; private set; }
        /// <summary>First physics hit reached by the arc, independent of landing validity.</summary>
        public RaycastHit? ArcHit { get; private set; }
        public Vector3 ArcEnd => drawn == 0 ? default : arc[drawn - 1];

        public void Cast(Vector3 origin, Vector3 normalizedDir, XRRayInteractor controllerRay, string teleportLayerName,
            float? launchSpeed = null, Transform ignoreRig = null)
        {
            CastWithMask(origin, normalizedDir, controllerRay,
                string.IsNullOrEmpty(teleportLayerName) ? 0 : InteractionLayerMask.GetMask(teleportLayerName), launchSpeed, ignoreRig);
        }

        /// <summary>Casts using a numeric XRI interaction mask, without looking up layer names.</summary>
        public void CastWithMask(Vector3 origin, Vector3 normalizedDir, XRRayInteractor controllerRay,
            InteractionLayerMask interactionMask, float? launchSpeed = null, Transform ignoreRig = null)
        {
            var speed = launchSpeed ?? (controllerRay ? controllerRay.velocity : DefaultLaunchSpeed);
            var gravity = controllerRay ? controllerRay.acceleration : DefaultGravity;
            var mask = controllerRay ? (int)controllerRay.raycastMask : Physics.DefaultRaycastLayers;
            var triggers = controllerRay ? controllerRay.raycastTriggerInteraction : QueryTriggerInteraction.Ignore;
            teleportMask = interactionMask;
            TeleportArc.Sample(origin, normalizedDir, speed, gravity, arc);
            HasTarget = false;
            ArcHit = null;
            landingArea = null;
            drawn = arc.Length;
            for (var i = 1; i < arc.Length; i++)
            {
                var from = arc[i - 1];
                var step = arc[i] - from;
                var physicsHit = TeleportRaycast.Cast(from, step, step.magnitude, mask, triggers, ignoreRig, out var hit);
                if (IntersectBlockers(from, physicsHit ? hit.point : arc[i], out var blockerHit))
                {
                    arc[i] = blockerHit;
                    drawn = i + 1;
                    break;
                }
                if (!physicsHit) continue;
                ArcHit = hit;
                arc[i] = hit.point;
                drawn = i + 1;
                var area = hit.collider.GetComponentInParent<BaseTeleportationInteractable>();
                if (!AllowsLanding(hit, area)) break;

                landing = hit;
                landingArea = area;
                HasTarget = true;
                Target = new TeleportRequest
                {
                    destinationPosition = hit.point,
                    destinationRotation = area.transform.rotation,
                    matchOrientation = area.matchOrientation,
                };
                break;
            }
        }

        bool AllowsLanding(RaycastHit hit, BaseTeleportationInteractable area)
        {
            var collider = hit.collider;
            // The request uses the hit point, not an anchor's independently authored pose.
            return area && (AllowAnchorSurfaces || area is TeleportationArea) && area.isActiveAndEnabled && (area.interactionLayers & teleportMask) != 0
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

        /// <summary>Checks current UI and policies without resampling the frozen arc or changing its request.
        /// A rejected target stays invalid until the next cast.</summary>
        public bool Revalidate()
        {
            if (!HasTarget) return false;
            if (!AllowsLanding(landing, landingArea)) return HasTarget = false;
            for (var i = 1; i < drawn; i++)
                if (IntersectBlockers(arc[i - 1], arc[i], out _)) return HasTarget = false;
            return true;
        }

        public void Show(bool on, LineRenderer line, Gradient validColor, Gradient invalidColor, GameObject reticle, Transform head,
            bool highlight = true)
        {
            ShowReticle(on && HasTarget && highlight, reticle, head);
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
            reticle.transform.SetPositionAndRotation(Target.destinationPosition, ReticleRotation(head));
        }

        Quaternion ReticleRotation(Transform head)
        {
            if (Target.matchOrientation == MatchOrientation.TargetUpAndForward) return Target.destinationRotation;

            // For modes that do not set yaw, preview the head's heading around the destination up.
            var up = Target.matchOrientation == MatchOrientation.TargetUp
                ? Target.destinationRotation * Vector3.up : Vector3.up;
            var fwd = Vector3.ProjectOnPlane(head ? head.forward : Vector3.forward, up);
            if (fwd.sqrMagnitude < 1e-6f) fwd = Vector3.ProjectOnPlane(Vector3.forward, up);
            if (fwd.sqrMagnitude < 1e-6f) fwd = Vector3.ProjectOnPlane(Vector3.right, up);
            return Quaternion.LookRotation(fwd, up);
        }
    }
}
