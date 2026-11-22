using System;
using System.Runtime.CompilerServices;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace YetiKit.Interaction
{
    /// <summary>Shoulder-to-pinch aiming with live, release-to-teleport confirmation.</summary>
    [DefaultExecutionOrder(PlayerHand.ExecutionOrder + 4)]
    public sealed class PointPinchTeleport : MonoBehaviour
    {
        public const float Cooldown = 0.75f, ReleaseQuietTime = 0.1f, MaxTipDrop = 0.6f;
        public PlayerHand hand;
        public Transform head, rig;
        public TeleportationProvider provider;
        public XRRayInteractor controllerRay;
        [Tooltip("Inherit launch speed and gravity from the controller ray rather than the hand settings below.")]
        public bool useControllerArcSettings = true;
        public float launchSpeed = 5f;
        public float gravity = TeleportAim.DefaultGravity;
        public LineRenderer line;
        public Gradient validColor, invalidColor;
        public GameObject reticle;
        [Tooltip("Explicit XRI interaction layers. Zero uses the layer name below.")]
        public InteractionLayerMask teleportInteractionMask;
        public string teleportLayerName = "Teleport";

        sealed class RigState { public float Until = float.NegativeInfinity; }
        static readonly ConditionalWeakTable<Transform, RigState> States = new();
        readonly PointPinchGesture gesture = new();
        readonly PointPinchPose pose = new();
        readonly AngularOneEuro yaw = new(), pitch = new();
        float sampledAt = float.NaN, quietUntil = float.NegativeInfinity;
        float seenCooldown = float.NegativeInfinity;
        int poseEpoch = -1;
        bool awaitingOpen;
        PlayerHand blockedHand;
        public bool Aiming => gesture.Aiming;
        public bool Pinching => gesture.Pinching;
        public Ray AimRay { get; private set; }
        public TeleportAim Aim { get; } = new() { AllowAnchorSurfaces = true };
        public event Action<string> Cancelled;
        Transform Rig => rig ? rig : provider ? provider.transform : transform.root;
        HandAimOwnership Ownership => HandAimOwnership.For(Rig);
        public InteractionLayerMask AimMask => teleportInteractionMask.value != 0 ? teleportInteractionMask :
            (InteractionLayerMask)(string.IsNullOrEmpty(teleportLayerName) ? 0 : InteractionLayerMask.GetMask(teleportLayerName));

        void OnEnable() => Show(false);
        void OnDisable() => ResetAim();
        void OnDestroy() => Aim.DestroyReticle();
        void Update() => Tick(Time.time, HandTeleport.Holding(hand));
        // Both hands may preview, but the first pinch hides the other preview before rendering.
        void LateUpdate()
        {
            if (!Aiming) return;
            if (!Ownership.IsAvailable(this)) Cancel("busy");
            else if (Time.time < States.GetOrCreateValue(Rig).Until) ResetAim();
        }

        public bool Tick(float now, bool holding)
        {
            if (!isActiveAndEnabled) return false;
            if (!hand || !hand.isActiveAndEnabled || !hand.HandTracked ||
                (controllerRay && controllerRay.isActiveAndEnabled)) return Cancel("lost");
            if (poseEpoch != hand.PoseEpoch) Cancel("lost");
            poseEpoch = hand.PoseEpoch;
            var tip = hand.Joint(PinchStrength.IndexTip);
            var thumb = hand.Joint(PinchStrength.ThumbTip);
            var gap = Vector3.Distance(tip, thumb);
            var state = States.GetOrCreateValue(Rig);
            if (seenCooldown != state.Until)
            {
                seenCooldown = state.Until;
                awaitingOpen = true;
                ResetAim();
            }
            if (now < seenCooldown || (awaitingOpen && !(gap > PointPinchGesture.PinchRelease))) return false;
            awaitingOpen = false;
            if (holding) quietUntil = now + ReleaseQuietTime;
            if (holding || now < quietUntil || (hand.grabber && now < hand.grabber.SelectionEndedAt + ReleaseQuietTime))
                return Cancel("holding");
            if (hand.FarInteraction.UiHover || ReachGuard.Near(tip, TeleportAim.UiReach, hand.transform)) return Cancel("reach");
            if (!Ownership.IsAvailable(this)) return Cancel("busy");
            if (!head || tip.y < head.position.y - MaxTipDrop || hand.Shape == HandShape.Fist) return Cancel("pose");
            var fwd = Vector3.ProjectOnPlane(head.forward, Vector3.up).normalized;
            if (fwd == Vector3.zero) fwd = Vector3.forward;
            if (!pose.Tick(PointPinchPalm.Normal(hand), fwd, hand.FingerCurls, now, Pinching || gap < PointPinchGesture.PinchEnter))
                return Aiming ? Cancel("pose") : false;
            if ((Pinching || gap < PointPinchGesture.PinchEnter) && !PointPinchPose.CanConfirm(hand.FingerCurls))
                return Cancel("pose");

            var origin = (tip + thumb) * 0.5f;
            var direction = Smooth(PointPinchPalm.Direction(head.position, fwd, hand.RightHand, origin), now);
            AimRay = new Ray(origin, direction);
            Aim.CastWithMask(origin, direction, controllerRay, AimMask,
                useControllerArcSettings ? null : launchSpeed, Rig, useControllerArcSettings ? null : gravity);
            Aim.HasTarget = Aim.HasTarget && TeleportGround.Matches(Aim.ArcHit.GetValueOrDefault(), Rig);
            var wasPinching = Pinching;
            var result = gesture.Tick(true, false, true, false, gap, Aim.HasTarget, true);
            if (result == PointPinchResult.Cancel) return Cancel(gesture.LastCancel);
            if (result == PointPinchResult.Teleport)
            {
                var request = Aim.Target;
                request.requestTime = now;
                if (!provider || !provider.isActiveAndEnabled || !provider.QueueTeleportRequest(request)) return Cancel("no-target");
                state.Until = now + Cooldown;
                ResetAim();
                return true;
            }
            if (!wasPinching && Pinching) Ownership.Claim(this, Preempted);
            if (blockedHand && blockedHand != hand) blockedHand.GrabBlocked = false;
            blockedHand = hand;
            hand.GrabBlocked = true;
            Show(true);
            return false;
        }

        Vector3 Smooth(Vector3 dir, float now)
        {
            var y = Mathf.Atan2(dir.x, dir.z) * Mathf.Rad2Deg;
            var p = Mathf.Asin(Mathf.Clamp(dir.y, -1f, 1f)) * Mathf.Rad2Deg;
            if (float.IsNaN(sampledAt)) { yaw.Reset(y); pitch.Reset(p); }
            var dt = now - sampledAt;
            sampledAt = now;
            return Quaternion.Euler(-pitch.Step(p, dt), yaw.Step(y, dt), 0f) * Vector3.forward;
        }

        bool Cancel(string reason)
        {
            var wasAiming = Aiming;
            ResetAim();
            if (wasAiming) Cancelled?.Invoke(reason);
            return false;
        }

        void Preempted() => Cancel("busy");

        void ResetAim()
        {
            Ownership.Release(this);
            gesture.Reset();
            pose.Reset();
            sampledAt = float.NaN;
            Aim.HasTarget = false;
            if (blockedHand) blockedHand.GrabBlocked = false;
            blockedHand = null;
            Show(false);
        }

        void Show(bool on) => Aim.Show(on, line, validColor, invalidColor, reticle, head, Pinching);
    }
}
