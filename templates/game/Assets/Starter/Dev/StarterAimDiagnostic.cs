#if UNITY_EDITOR || YETIKIT_DEV
using System;
using System.Linq;
using Game.Starter;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace Game.Dev
{
    // Installed at runtime: the baked scene never references Game.Dev.
    public sealed class StarterAimDiagnostic : MonoBehaviour
    {
        const double Interval = 0.2;
        Side[] sides;
        double nextLog;
        int nextSide;

        internal static void Install(StarterLab lab, Transform rig)
        {
            lab.gameObject.AddComponent<StarterAimDiagnostic>().sides = rig.GetComponentsInChildren<HandTeleport>()
                .Where(aim => aim.hand && aim.line && aim.controllerRay).Select(aim => new Side(aim)).ToArray();
        }

        void LateUpdate() => Sample(Time.unscaledTimeAsDouble);

        internal void Sample(double now)
        {
            if (sides == null || sides.Length == 0) return;
            // Keep the last *live* hand cast even while throttled, so thumb drop reports the frozen arc.
            foreach (var side in sides) side.Observe();
            if (now < nextLog) return;
            for (var offset = 0; offset < sides.Length; offset++)
            {
                var index = (nextSide + offset) % sides.Length;
                if (!sides[index].LogChange()) continue;
                nextSide = (index + 1) % sides.Length;
                nextLog = now + Interval;
                break;
            }
        }

        sealed class Side
        {
            readonly HandTeleport aim;
            readonly PlayerHand hand;
            readonly XRRayInteractor ray;
            readonly ControllerTracking controller;
            readonly Vector3[] points = new Vector3[TeleportArc.Segments + 1];
            bool handActive, controllerActive;
            string lastLine;
            Vector3 handOrigin, handForward, handEnd;
            RaycastHit handHit;

            public Side(HandTeleport aim)
            {
                this.aim = aim;
                hand = aim.hand;
                ray = aim.controllerRay;
                controller = hand.GetComponent<ControllerTracking>();
            }

            public void Observe()
            {
                handActive = aim.isActiveAndEnabled && aim.Aiming && aim.line.enabled;
                // The starter ray is a live aim whenever enabled, even before a trigger press.
                controllerActive = ray.isActiveAndEnabled;
                if (!handActive && !controllerActive) lastLine = null;
                if (handActive && !aim.Gesture.Dropping) ObserveHandCast();
            }

            void ObserveHandCast()
            {
                handOrigin = aim.line.GetPosition(0);
                handForward = (hand.Joint(PinchStrength.IndexTip) - hand.Joint(HandTeleport.IndexProximal)).normalized;
                var end = aim.line.positionCount - 1;
                handEnd = aim.line.GetPosition(end);
                // Reconstruct only the final segment of the actual drawn hand arc. The kit does not expose
                // its rejected hit. A hit beyond the drawn endpoint (e.g. behind UI) is not the arc's hit.
                TeleportArc.Sample(handOrigin, handForward, ray.velocity, ray.acceleration, points);
                var from = points[end - 1];
                var step = points[end] - from;
                if (!Physics.Raycast(from, step, out handHit, step.magnitude, ray.raycastMask, ray.raycastTriggerInteraction) ||
                    (handHit.point - handEnd).sqrMagnitude > 0.000001f)
                    handHit = default;
            }

            public bool LogChange()
            {
                if (!handActive && !controllerActive) return false;
                var value = handActive ? HandLine() : ControllerLine();
                if (value == lastLine) return false;
                lastLine = value;
                Debug.Log(value, aim);
                return true;
            }

            string HandLine()
            {
                var collider = handHit.collider;
                var target = collider ? collider.GetComponentInParent<BaseTeleportationInteractable>() : null;
                var mask = InteractionLayerMask.GetMask(aim.TeleportLayerName);
                var valid = aim.HasTarget;
                var shortened = (handEnd - points[points.Length - 1]).sqrMagnitude > 0.000001f;
                var reason = valid ? "none" : !collider ? (shortened ? "no-hit/arc-stopped (UI or custom blocker)" : "no-hit") :
                    target is not TeleportationArea ? "not-a-teleport-interactable/first-collider" :
                    (target.interactionLayers & mask) == 0 ? "interaction-layer-mismatch" :
                    handHit.normal.y < TeleportAim.MinUp ? "normal-or-angle" : "landing-rejected (disabled, UI or policy)";
                var interactable = target ? target : collider ? collider.GetComponentInParent<XRBaseInteractable>() : null;
                int? hitMask = interactable ? (int)interactable.interactionLayers : null;
                return Line("hand", aim.Gesture.Dropping ? "thumb-dropping" : "aiming", handOrigin, handForward,
                    handHit, hitMask, mask, valid, "n/a", reason);
            }

            string ControllerLine()
            {
                ray.GetLineOriginAndDirection(out var origin, out var forward);
                ray.TryGetCurrent3DRaycastHit(out var hit);
                ray.TryGetHitInfo(out _, out _, out _, out var xriValid);
                var manager = ray.interactionManager;
                IXRInteractable target = null;
                if (hit.collider && manager) manager.TryGetInteractableForCollider(hit.collider, out target);
                var area = target as BaseTeleportationInteractable;
                var valid = xriValid && area && (ray.IsSelecting((IXRSelectInteractable)area) || manager.IsSelectPossible(ray, area));
                var reason = valid ? "none" : !hit.collider ? "no-hit" :
                    !area ? "not-a-teleport-interactable/first-collider" :
                    (area.interactionLayers & ray.interactionLayers) == 0 ? "interaction-layer-mismatch" :
                    area.filterSelectionByHitNormal && Vector3.Angle(area.transform.up, hit.normal) > area.upNormalToleranceDegrees
                        ? "normal-or-angle" : "XRI hover or selection rejected";
                return Line("controller", ray.hasSelection ? "selected" : controller && controller.TriggerPressed ? "trigger-down" : "ready",
                    origin, forward, hit, target == null ? null : (int)target.interactionLayers, ray.interactionLayers,
                    valid, xriValid ? "True" : "False", reason);
            }

            string Line(string mode, string gesture, Vector3 origin, Vector3 forward, RaycastHit hit,
                int? hitMask, int aimMask, bool valid, string xriValid, string reason)
            {
                var collider = hit.collider;
                var name = collider ? collider.name.Replace('\n', ' ').Replace('\r', ' ') : "n/a";
                var layer = collider ? collider.gameObject.layer.ToString() : "n/a";
                var firstBlocker = reason.EndsWith("/first-collider", StringComparison.Ordinal) ? name : "n/a";
                return $"StarterAim side={(hand.RightHand ? "right" : "left")} mode={mode} gesture={gesture} " +
                    $"origin={World(origin)} forward={World(forward)} hit={collider != null} collider=\"{name}\" " +
                    $"gameObjectLayer={layer} interactionMask={Mask(hitMask)} aimMask={Mask(aimMask)} " +
                    $"hitPoint={(collider ? World(hit.point) : "n/a")} hitNormal={(collider ? World(hit.normal) : "n/a")} " +
                    $"aimValid={valid} xriValid={xriValid} reason=\"{reason}\" firstBlocker=\"{firstBlocker}\" " +
                    $"handTracked={hand.HandTracked} wrist={World(hand.WristPose.position)} indexTip={World(hand.Joint(PinchStrength.IndexTip))}";
            }

            static string Mask(int? value) => value.HasValue ? $"0x{value.Value:X8}" : "n/a";
            static string World(Vector3 v) => FormattableString.Invariant($"({v.x:F3},{v.y:F3},{v.z:F3})");
        }
    }
}
#endif
