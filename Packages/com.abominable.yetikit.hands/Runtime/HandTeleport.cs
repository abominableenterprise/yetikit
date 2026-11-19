using System;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;

namespace YetiKit.Hands
{
    /// <summary>Forward index point to aim, thumb drop to queue a teleport on the rig's XRI provider.</summary>
    [DefaultExecutionOrder(PlayerHand.ExecutionOrder + 1)]
    public sealed class HandTeleport : MonoBehaviour
    {
        public const int IndexProximal = HandCurls.PointsPerFinger + 1;
        public const float MinUp = TeleportAim.MinUp;

        public PlayerHand hand;
        public Transform head;
        public TeleportationProvider provider;
        public XRRayInteractor controllerRay;
        public LineRenderer line;
        public Gradient validColor, invalidColor;
        public GameObject reticle;
        [Tooltip("Shared aim lease key. Defaults to the hand's tracking-space parent.")]
        public Transform rig;
        [SerializeField, Tooltip("XRI interaction layer, not a physics layer.")]
        string teleportLayerName = "Teleport";

        readonly HandTeleportGesture gesture = new();
        readonly TeleportAim aim = new();
        HandAimOwnership lease;
        PlayerHand blockedHand;

        public string TeleportLayerName { get => teleportLayerName; set => teleportLayerName = value; }
        public HandTeleportGesture Gesture => gesture;
        public TeleportAim Aim => aim;
        public bool Aiming => gesture.Aiming;
        public bool HasTarget => aim.HasTarget;
        public TeleportRequest Target => aim.Target;
        public event Action<bool, Vector3> AimEnded;
        public Func<object, bool> CanPreempt { get; set; }

        void OnEnable() => Show(false);

        void OnDisable()
        {
            var wasAiming = Aiming;
            var destination = Target.destinationPosition;
            gesture.Reset();
            SetGrabBlocked(false);
            EndPreview();
            if (wasAiming) AimEnded?.Invoke(false, destination);
        }

        void OnDestroy() => aim.DestroyReticle(reticle);
        void Update() => Tick(Time.time, Holding(hand));
        public static bool Holding(PlayerHand h) => h && h.grabber && h.grabber.hasSelection;

        public bool Tick(float now, bool holding)
        {
            if (!isActiveAndEnabled) return false;
            var tracked = hand && hand.isActiveAndEnabled && hand.HandTracked;
            var origin = tracked ? hand.Joint(PinchStrength.IndexTip) : default;
            var dir = tracked ? (origin - hand.Joint(IndexProximal)).normalized : default;
            var fwd = head ? Vector3.ProjectOnPlane(head.forward, Vector3.up).normalized : Vector3.forward;
            var suppressed = tracked && (!hand.FarInteraction.AllowsTeleport(holding) || HandUiGuard.Near(origin, TeleportAim.UiReach));
            var wasAiming = Aiming;
            var confirmed = gesture.Tick(tracked, tracked && hand.Shape == HandShape.Point,
                Vector3.Dot(dir, fwd) >= HandTeleportGesture.ForwardMin, tracked ? hand.Hammer : 0f,
                tracked ? hand.Pinch : 0f, holding, now, suppressed);
            var gestureEnded = wasAiming && !Aiming;

            if (Aiming && lease == null)
            {
                var key = rig ? rig : hand.transform.parent ? hand.transform.parent : hand.transform;
                var ownership = HandAimOwnership.For(key);
                if (ownership.Claim(this, Preempted, CanPreempt) && isActiveAndEnabled && Aiming) lease = ownership;
                else
                {
                    ownership.Release(this);
                    gesture.Reset();
                }
            }

            if (Aiming && !gesture.Dropping) aim.Cast(origin, dir, controllerRay, teleportLayerName);
            if ((gesture.Dropping || confirmed) && HasTarget) aim.Revalidate();
            var request = Target;
            var shouldQueue = confirmed && HasTarget && provider;
            SetGrabBlocked(gesture.Busy);
            if (Aiming) Show(true);
            else EndPreview();
            request.requestTime = now;
            var teleported = shouldQueue && provider && provider.isActiveAndEnabled && provider.QueueTeleportRequest(request);
            if (gestureEnded) AimEnded?.Invoke(teleported, request.destinationPosition);
            return teleported;
        }

        void Preempted()
        {
            var wasAiming = Aiming;
            var destination = Target.destinationPosition;
            var pinch = hand && hand.isActiveAndEnabled && hand.HandTracked ? hand.Pinch : 0f;
            gesture.CancelForTakeover(pinch);
            SetGrabBlocked(gesture.Busy);
            EndPreview();
            if (wasAiming) AimEnded?.Invoke(false, destination);
        }

        void SetGrabBlocked(bool blocked)
        {
            if (blockedHand && (!blocked || blockedHand != hand)) blockedHand.GrabBlocked = false;
            blockedHand = blocked ? hand : null;
            if (blockedHand) blockedHand.GrabBlocked = true;
        }

        void EndPreview()
        {
            lease?.Release(this);
            lease = null;
            aim.HasTarget = false;
            Show(false);
        }

        void Show(bool on) => aim.Show(on, line, validColor, invalidColor, reticle, head);
    }
}
