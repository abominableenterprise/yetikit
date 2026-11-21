using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;

namespace YetiKit.Hands
{
    /// <summary>Feeds a tracked-hand turn gesture into one side of an XRI snap-turn provider.</summary>
    [DefaultExecutionOrder(PlayerHand.ExecutionOrder + 5)]
    public sealed class HandSnapTurn : MonoBehaviour
    {
        public const int ThumbProximal = 2, ThumbTip = HandCurls.PointsPerFinger - 1;
        public const int IndexIntermediate = HandCurls.PointsPerFinger + 2;

        public PlayerHand hand;
        [Tooltip("The head transform defines left and right for the gesture.")]
        public Transform head;
        public SnapTurnProvider provider;
        public HandTeleport teleport;

        Vector3 last;
        bool hasLast;
        float lastSampleAt = float.NegativeInfinity;
        public HandTurnGesture Gesture { get; } = new HandTurnGesture();
        public HandTurnInput Input { get; } = new HandTurnInput();
        /// <summary>An external aiming interaction is using this hand.</summary>
        public bool AimBusy { get; set; }
        /// <summary>Discard turn gesture progress while another interaction owns the gesture.</summary>
        public bool GestureSuppressed { get; set; }

        void OnEnable() => Attach();

        /// <summary>Attach the bypass after assigning the hand and provider in code.</summary>
        public void Attach() => Input.Attach(!provider || !hand ? null :
            hand.RightHand ? provider.rightHandTurnInput : provider.leftHandTurnInput);

        void OnDisable()
        {
            Input.Detach();
            Gesture.Reset();
            hasLast = false;
            lastSampleAt = float.NegativeInfinity;
        }

        void Update() => Tick(Time.time, Time.deltaTime, hand && hand.isActiveAndEnabled && HandTeleport.Holding(hand));

        /// <summary>Sample one frame after the hand has updated. Returns the turn direction, or zero.</summary>
        public int Tick(float now, float dt, bool holding)
        {
            if (!isActiveAndEnabled) return 0;
            if (GestureSuppressed || !hand || !hand.isActiveAndEnabled || !provider || !provider.isActiveAndEnabled)
            {
                Gesture.Reset();
                Input.Pulse(0);
                hasLast = false;
                return 0;
            }

            // A cached pose is neither progress toward the hold nor a release of an already-fired pose.
            var sampleAt = hand.HandSampleAt;
            var tracked = hand.HandTracked && sampleAt != float.NegativeInfinity && sampleAt != lastSampleAt;
            if (tracked) lastSampleAt = sampleAt;
            var pos = hand.transform.localPosition; // Movement of the rig is not movement of the hand.
            var speed = tracked && hasLast && dt > 0f ? Vector3.Distance(pos, last) / dt : 0f;
            last = pos;
            hasLast = tracked;
            var tip = hand.Joint(ThumbTip);
            var thumb = tip - hand.Joint(ThumbProximal);
            var right = head ? Vector3.ProjectOnPlane(head.right, Vector3.up).normalized : Vector3.right;
            var sideways = Vector3.Dot(thumb.normalized, right);
            var reach = Vector3.Distance(tip, hand.Joint(IndexIntermediate));
            var busy = holding || AimBusy || hand.GrabBlocked || (teleport && teleport.Gesture.Busy);
            var turn = Gesture.Tick(tracked, hand.Shape == HandShape.Fist, hand.FingerCurls.thumb, sideways, reach, speed, busy, now);
            if (turn != 0 || !tracked || busy) Input.Pulse(turn);
            return turn;
        }
    }
}
