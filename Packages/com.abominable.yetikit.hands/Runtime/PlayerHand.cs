using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.XR.Hands;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Haptics;
using UnityEngine.XR.Interaction.Toolkit.Interactors;

namespace YetiKit.Hands
{
    /// <summary>One side's hand root, normally a sibling of the controller under the tracking-space transform.</summary>
    [DefaultExecutionOrder(ExecutionOrder)]
    public sealed class PlayerHand : MonoBehaviour, IHandInput
    {
        public const int ExecutionOrder = -200;
        // Allow a short gap between Dynamic updates, then treat cached joints as tracking loss.
        const float DynamicSampleMaxAge = 0.05f;

        public bool rightHand = true;
        public Transform controller;
        public HapticImpulsePlayer haptics;
        public HandGrabInteractor grabber;
        public HandCue cue;
        [SerializeField, Tooltip("Optional component implementing IHandVisual.")]
        MonoBehaviour visual;

        static IHandTracking sharedTracking;
        static readonly List<PlayerHand> live = new List<PlayerHand>();
        static readonly int palmIndex = XRHandJointID.Palm.ToIndex();

        readonly Vector3[] points = new Vector3[HandCurls.Points];
        readonly Vector3[] pendingPoints = new Vector3[HandCurls.Points];
        readonly JointCurls curls = new JointCurls();
        readonly Vector3[] renderPoints = new Vector3[HandCurls.Points];
        readonly JointCurls renderCurls = new JointCurls();
        readonly Pose[] visualPoses = new Pose[XrHandTracking.AllJoints];
        readonly Pose[] wristAndPalm = new Pose[palmIndex + 1];
        readonly HandShapeClassifier classifier = new HandShapeClassifier();
        readonly HandGrabGesture grab = new HandGrabGesture();
        IHandTracking tracking;
        IHandVisual visualOverride, notifiedVisual;
        System.Action follow;
        float controllerGrip, controllerTrigger, handGrip;
        bool endingGrab, notifiedPresence;
        int disableEpoch;
        Pose dynamicWrist = Pose.identity, dynamicPalm = Pose.identity;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void ResetRegistry()
        {
            live.Clear();
            sharedTracking = null;
        }

        /// <summary>XR Hands by default. Assign null to return to the default provider.</summary>
        public IHandTracking Tracking
        {
            get => tracking ??= sharedTracking ??= new XrHandTracking();
            set => tracking = value;
        }

        /// <summary>Code override for the optional serialized visual; null falls back to the inspector field.</summary>
        public IHandVisual Visual
        {
            get => visualOverride is Object obj && !obj ? null : visualOverride ?? (visual ? visual as IHandVisual : null);
            set
            {
                visualOverride = value;
                if (isActiveAndEnabled) NotifyVisual();
            }
        }

        public bool RightHand => rightHand;
        public HandMode Mode { get; private set; }
        /// <summary>Changes when the pose source switches or tracking is lost.</summary>
        public int PoseEpoch { get; private set; }
        public bool HandTracked => Mode == HandMode.TrackedHand;
        public bool Present => Mode != HandMode.None;
        /// <summary>Unscaled time of the latest valid Dynamic joint sample, or negative infinity when unavailable.</summary>
        public float HandSampleAt { get; private set; } = float.NegativeInfinity;
        public event System.Action PresenceChanged;
        public HandShape Shape => HandTracked ? classifier.Shape : HandShape.Relaxed;
        public float Grip => HandTracked ? handGrip : controllerGrip;
        public float Trigger => HandTracked ? grab.Trigger : controllerTrigger;
        public float Pinch { get; private set; }
        public float Press { get; private set; }
        public float Hammer { get; private set; }
        public HandGrabGesture Grab => grab;
        public bool GrabberActive => HandTracked || (Mode == HandMode.None && grab.InGrace);
        public JointCurls Curls => curls;
        public FingerCurls FingerCurls { get; private set; }
        public bool GrabBlocked { get; set; }
        public HandFarInteraction FarInteraction { get; } = new HandFarInteraction();

        /// <summary>A Dynamic tracked joint (<see cref="HandCurls"/> point order), in world space.</summary>
        public Vector3 Joint(int i) => transform.parent ? transform.parent.TransformPoint(points[i]) : points[i];

        /// <summary>The Dynamic tracked wrist in world space; retains the last tracked sample on loss.</summary>
        public Pose WristPose => ToWorld(dynamicWrist);

        /// <summary>Palm attachment in world space. On loss, the last palm is retained until another source drives the root.</summary>
        public Pose PalmPose => Mode == HandMode.Controller && controller
            ? new Pose(controller.position, controller.rotation) : ToWorld(dynamicPalm);

        Pose ToWorld(Pose pose)
        {
            var parent = transform.parent;
            return parent ? new Pose(parent.TransformPoint(pose.position), parent.rotation * pose.rotation) : pose;
        }

        public static bool IsPresent(Transform t)
        {
            if (!t || !t.gameObject.activeInHierarchy) return false;
            var hand = t.GetComponent<PlayerHand>();
            return !hand || !hand.enabled || hand.Present;
        }

        /// <summary>Find the hand from its own hierarchy or its controller's hierarchy.</summary>
        public static PlayerHand Of(Transform t)
        {
            if (!t) return null;
            var own = t.GetComponentInParent<PlayerHand>(true);
            if (own) return own;
            for (var ancestor = t; ancestor && ancestor.parent; ancestor = ancestor.parent)
            {
                var siblings = ancestor.parent;
                for (var i = 0; i < siblings.childCount; i++)
                {
                    var hand = siblings.GetChild(i).GetComponent<PlayerHand>();
                    if (hand && hand.controller == ancestor) return hand;
                }
            }
            return null;
        }

        public static PlayerHand Side(bool right)
        {
            foreach (var hand in live) if (hand && hand.rightHand == right) return hand;
            return null;
        }

        /// <summary>Report the controller's current grip and trigger.</summary>
        public void Report(float grip, float trigger)
        {
            if (Mode != HandMode.Controller) return;
            controllerGrip = grip;
            controllerTrigger = trigger;
            NotifyVisual()?.OnControllerInput(grip, trigger);
        }

        public bool Haptic(float amplitude, float seconds)
        {
            if (HandTracked && cue) cue.Play(amplitude, Time.time);
            return Mode == HandMode.Controller && haptics && haptics.SendHapticImpulse(amplitude, seconds);
        }

        /// <summary>Read every XR Hands joint in world space into an array of at least <see cref="XrHandTracking.AllJoints"/> poses.</summary>
        public bool TryJointPoses(Pose[] poses) => HandTracked && ReadJointPoses(poses);

        bool ReadJointPoses(Pose[] poses)
        {
            if (poses == null || poses.Length < XrHandTracking.AllJoints ||
                !(Tracking is IHandJointPoses joints) || !joints.TryGetJointPoses(rightHand, poses)) return false;
            for (var i = 0; i < XrHandTracking.AllJoints; i++) poses[i] = ToWorld(poses[i]);
            return true;
        }

        /// <summary>World-space tip of a tracked, straight index finger.</summary>
        public bool TryIndexTip(out Vector3 tip)
        {
            tip = default;
            if (!HandTracked || FingerCurls.index > HandPoke.IndexStraight) return false;
            tip = Joint(PinchStrength.IndexTip);
            return true;
        }

        void OnEnable()
        {
            if (!live.Contains(this)) live.Add(this);
            follow ??= Follow;
            Application.onBeforeRender += Follow;
            XrHandTracking.BeforeRender += RenderSample;
            Resubscribe();
        }

        void OnDisable()
        {
            disableEpoch++;
            live.Remove(this);
            Application.onBeforeRender -= Follow;
            XrHandTracking.BeforeRender -= RenderSample;
            InputSystem.onAfterUpdate -= follow;
            EndHandGrab();
            grab.Reset();
            SetMode(HandMode.None);
            notifiedVisual = null;
        }

        // Run after the controller's pose driver, even after it re-subscribes on a modality change.
        void Resubscribe()
        {
            InputSystem.onAfterUpdate -= follow;
            InputSystem.onAfterUpdate += follow;
        }

        void Update()
        {
            Resubscribe();
            Tick();
        }

        void LateUpdate() => Follow();

        public void Tick() => Tick(Time.time, Time.unscaledTime);

        /// <summary>Sample with a synthetic clock, for replays and tests.</summary>
        public void Tick(float now) => Tick(now, now);

        void Tick(float now, float sampleTime)
        {
            if (!isActiveAndEnabled || endingGrab) return;
            if (ControllerActive)
            {
                Follow();
                return;
            }

            var source = Tracking;
            if (source.TryGetHand(rightHand, pendingPoints, out var wrist))
            {
                var sampledAt = source is XrHandTracking xr ? xr.LastDynamicSampleAt(rightHand) : sampleTime;
                if (sampleTime <= sampledAt + DynamicSampleMaxAge)
                {
                    System.Array.Copy(pendingPoints, points, points.Length);
                    HandSampleAt = sampledAt;
                    Track(wrist, now);
                    if (!SetMode(HandMode.TrackedHand) || ControllerActive) return;
                    var transition = Transition;
                    if (grabber && !grabber.enabled) grabber.enabled = true;
                    if (CanContinue(transition) && !ControllerActive) SendPose(WristPose, curls);
                    return;
                }
            }

            grab.Tick(false, 0f, 0f, 0f, now);
            if (SetMode(HandMode.None) && !GrabberActive) EndHandGrab();
        }

        // A listener can synchronously disable the hand or start a different mode transition.
        (int pose, int disable) Transition => (PoseEpoch, disableEpoch);
        bool CanContinue((int pose, int disable) transition) => isActiveAndEnabled && Transition == transition;

        bool SetMode(HandMode mode)
        {
            var transition = Transition;
            if (mode != Mode)
            {
                if (Mode == HandMode.TrackedHand)
                {
                    classifier.Reset();
                    FingerCurls = default;
                    handGrip = Pinch = Press = Hammer = 0f;
                    HandSampleAt = float.NegativeInfinity;
                }
                if (Mode == HandMode.Controller) controllerGrip = controllerTrigger = 0f;
                Mode = mode;
                PoseEpoch++;
                transition = Transition;
                PresenceChanged?.Invoke();
            }
            if (Transition == transition) NotifyVisual();
            return CanContinue(transition);
        }

        IHandVisual NotifyVisual()
        {
            var current = Visual;
            if (current != null && (!ReferenceEquals(current, notifiedVisual) || Present != notifiedPresence))
            {
                notifiedVisual = current;
                notifiedPresence = Present;
                current.OnPresence(Present);
            }
            return current;
        }

        void EndHandGrab()
        {
            if (endingGrab || !grabber || !grabber.enabled) return;
            endingGrab = true;
            try
            {
                // Cancel before disabling so release callbacks see the last tracked root and unregistration cannot release it twice.
                if (grabber.hasSelection && grabber.interactionManager)
                    grabber.interactionManager.CancelInteractorSelection((IXRSelectInteractor)grabber);
                grabber.enabled = false;
            }
            finally { endingGrab = false; }
        }

        void Track(Pose wrist, float now)
        {
            dynamicWrist = wrist;
            dynamicPalm = MeasurePalm(wrist);
            transform.SetLocalPositionAndRotation(wrist.position, wrist.rotation);
            HandCurls.Measure(points, curls);
            FingerCurls = HandCurls.PerFinger(curls);
            classifier.Tick(FingerCurls);
            handGrip = (FingerCurls.middle + FingerCurls.ring + FingerCurls.pinky) / 3f;
            Pinch = PinchStrength.From(points);
            Press = ThumbPress.From(points);
            Hammer = ThumbHammer.From(points);
            grab.Tick(true, handGrip, Pinch, Press, now);
        }

        Pose MeasurePalm(Pose wrist)
        {
            if (Tracking is IHandJointPoses joints && joints.TryGetJointPoses(rightHand, wristAndPalm))
                return wristAndPalm[palmIndex];

            var knuckles = Vector3.zero;
            for (var finger = YetiKit.Hands.FingerCurls.Index; finger <= YetiKit.Hands.FingerCurls.Pinky; finger++)
                knuckles += points[finger * HandCurls.PointsPerFinger + 1]; // proximal, after the metacarpal
            var center = Vector3.Lerp(wrist.position, knuckles * 0.25f, HandGrabInteractor.PalmAlong);
            // XR wrist +Y is dorsal; move toward the palm side, away from the back of the hand.
            return new Pose(center - wrist.rotation * Vector3.up * HandGrabInteractor.PalmDepth, wrist.rotation);
        }

        /// <summary>Give the visual a newer tracked sample without moving the gameplay root or changing its gesture.</summary>
        public void RenderSample()
        {
            if (!HandTracked || ControllerActive || Visual == null ||
                !Tracking.TryGetHand(rightHand, renderPoints, out var wrist)) return;
            HandCurls.Measure(renderPoints, renderCurls);
            SendPose(ToWorld(wrist), renderCurls);
        }

        void SendPose(Pose wrist, JointCurls sample)
        {
            var current = Visual;
            if (current != null) current.OnPose(wrist, sample, ReadJointPoses(visualPoses) ? visualPoses : null);
        }

        bool ControllerActive => controller && controller.gameObject.activeInHierarchy;

        /// <summary>Copy the active controller pose now.</summary>
        public void Sync() => Follow();

        void Follow()
        {
            if (!isActiveAndEnabled || endingGrab || !ControllerActive) return;
            var transition = Transition;
            var target = controller;
            // Release at the last hand position, before snapping the root to a different input source.
            EndHandGrab();
            if (!CanContinue(transition) || controller != target || !ControllerActive) return;
            grab.Reset();
            transform.SetPositionAndRotation(target.position, target.rotation);
            var changed = Mode != HandMode.Controller;
            if (SetMode(HandMode.Controller) && changed && ControllerActive)
                Visual?.OnControllerInput(controllerGrip, controllerTrigger);
        }
    }
}
