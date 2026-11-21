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
using YetiKit.Interaction;

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
            lab.gameObject.AddComponent<StarterAimDiagnostic>().sides = rig.GetComponentsInChildren<PointPinchTeleport>()
                .Where(aim => aim.hand && aim.line && aim.controllerRay).Select(aim => new Side(aim)).ToArray();
        }

        void LateUpdate() => Sample(Time.unscaledTimeAsDouble);

        internal void Sample(double now)
        {
            if (sides == null || sides.Length == 0) return;
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
            readonly PointPinchTeleport aim;
            readonly PlayerHand hand;
            readonly XRRayInteractor ray;
            readonly ControllerTracking controller;
            bool handActive, controllerActive;
            string lastLine, cancelled;

            public Side(PointPinchTeleport aim)
            {
                this.aim = aim;
                hand = aim.hand;
                ray = aim.controllerRay;
                controller = hand.GetComponent<ControllerTracking>();
                aim.Cancelled += reason => cancelled = reason;
            }

            public void Observe()
            {
                handActive = aim.isActiveAndEnabled && aim.Aiming && aim.line.enabled;
                // The starter ray is a live aim whenever enabled, even before a trigger press.
                controllerActive = ray.isActiveAndEnabled;
                if (!handActive && !controllerActive) lastLine = null;
            }

            public bool LogChange()
            {
                if (cancelled != null)
                {
                    Debug.Log($"StarterAim side={(hand.RightHand ? "right" : "left")} mode=hand gesture=cancelled reason=\"{cancelled}\"", aim);
                    cancelled = null;
                    return true;
                }
                if (!handActive && !controllerActive) return false;
                var value = handActive ? HandLine() : ControllerLine();
                if (value == lastLine) return false;
                lastLine = value;
                Debug.Log(value, aim);
                return true;
            }

            string HandLine()
            {
                var handHit = aim.Aim.ArcHit.GetValueOrDefault();
                var collider = handHit.collider;
                var target = collider ? collider.GetComponentInParent<BaseTeleportationInteractable>() : null;
                var mask = aim.AimMask;
                var valid = aim.Aim.HasTarget;
                var reason = valid ? "none" : !collider ? "no-hit/arc-stopped" :
                    !target ? "not-a-teleport-interactable/first-collider" :
                    (target.interactionLayers & mask) == 0 ? "interaction-layer-mismatch" :
                    handHit.normal.y < TeleportAim.MinUp ? "normal-or-angle" : "landing-rejected (disabled, UI or policy)";
                var interactable = target ? target : collider ? collider.GetComponentInParent<XRBaseInteractable>() : null;
                int? hitMask = interactable ? (int)interactable.interactionLayers : null;
                return Line("hand", aim.Pinching ? "pinching" : "aiming", aim.AimRay.origin, aim.AimRay.direction,
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
