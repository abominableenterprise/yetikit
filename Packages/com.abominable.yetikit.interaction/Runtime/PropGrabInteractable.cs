using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Utilities;
using YetiKit.Hands;

namespace YetiKit.Interaction
{
    /// <summary>Fits a prop to the hand and replaces XRI detach smoothing with tracked release motion.</summary>
    public sealed class PropGrabInteractable : XRGrabInteractable
    {
        public const float Gravity = 9.81f;
        const float DefaultNearReach = 0.25f;

        /// <summary>Host pause flag; controller motion history is reset while paused.</summary>
        public static bool GameplayPaused { get; set; }

        HandMode? gripModeOverride;
        HandMode heldGripMode = HandMode.Controller;
        bool modeDrop;

        /// <summary>Explicit runtime mode, otherwise the holding hand's last available modality.</summary>
        public HandMode GripMode => gripModeOverride ?? (hand
            ? hand.Mode == HandMode.None ? heldGripMode : hand.Mode
            : HandMode.Controller);

        /// <summary>A different effective mode drops the prop without throwing. Regrab to fit the new mode's profile.
        /// Null resumes automatic mode selection. Call outside XRI select callbacks.</summary>
        public void SetGripMode(HandMode? mode)
        {
            if (mode.HasValue && mode != HandMode.None && mode != HandMode.Controller && mode != HandMode.TrackedHand)
                throw new ArgumentOutOfRangeException(nameof(mode));
            gripModeOverride = mode;
            if (heldGripMode != GripMode) DropForModeChange();
        }

        public GripSpec CurrentGripFor(bool rightHand)
        {
            var source = GetComponent<IGripSource>();
            if (source is GrabbableProp prop) return prop.GripFor(rightHand, GripMode);
            if (GripMode == HandMode.TrackedHand && source is ITrackedGripSource tracked)
                return tracked.TrackedGripFor(rightHand);
            return source != null ? source.GripFor(rightHand) : default;
        }

        void DropForModeChange()
        {
            if (!isSelected && lateRelease == null) return;
            modeDrop = true;
            try
            {
                if (lateRelease != null)
                {
                    CancelLateRelease();
                    ClearReleaseVelocity();
                    NotifyRelease(committed: false);
                }
                if (isSelected && interactionManager)
                    interactionManager.CancelInteractableSelection((IXRSelectInteractable)this);
            }
            finally { modeDrop = false; }
        }

        void ClearReleaseVelocity()
        {
            haveRelease = false;
            ReleaseSource = null;
            releaseLinear = releaseAngular = Vector3.zero;
            Launched = false;
            if (!body.isKinematic)
            {
                body.linearVelocity = Vector3.zero;
                body.angularVelocity = Vector3.zero;
            }
        }

        Rigidbody body;
        Transform gripAttach, originalAttach;
        bool originalDynamicAttach;
        ControllerMotion motion;
        PlayerHand hand;
        IHeldVisual visual;
        Vector3 releaseLinear, releaseAngular;
        bool haveRelease;
        LateRelease lateRelease;
        ThrowSample latePeak; // Last eligible result; frames after the deadline never enter the launch.
        Vector3 lateLever;
        // The held centre in attach space, not the ridden body's offset (velocity tracking leaves the body lagging).
        Vector3 lateLeverLocal;
        Transform lateAttach;
        Transform releaseInteractor;
        bool releaseUnannounced; // also gates XRI's deferred Detach after an early completion or cancellation
        Vector3 lateLocalPosition;
        Quaternion lateLocalRotation;
        bool lateKinematic, lateGravity;
        float lateOpenedAt;
        Vector3 lateLastPosition;
        readonly RigFollow rig = new RigFollow();

        /// <summary>Optional canonical right-hand adjustment. Set and call <see cref="RefitGrip"/> to update a hold.</summary>
        public Pose GripAdjustment { get; set; } = Pose.identity;

        /// <summary>The tracking space moved the prop. Listeners with world-space history can carry it too.</summary>
        public event Action<RigCarry> CarriedByRig;

        /// <summary>Raised after the actual launch or committed drop, not when the grip first opens.</summary>
        public event Action LaunchedFromHand;
        /// <summary>Count of committed launches/drops; hand-to-hand passes do not advance it.</summary>
        public ulong ReleaseSequence { get; private set; }
        public bool PendingLateRelease => lateRelease != null;
        public Vector3 ReleaseVelocity => releaseLinear;
        /// <summary>Whether the last release applied a throw at or above the impact speed threshold.</summary>
        public bool Launched { get; private set; }
        public string ReleaseSource { get; private set; }

        /// <summary>Before XRI records body flags. A scripted owner may give up the body here.</summary>
        public event Action<PropGrabInteractable> Grabbing;
        /// <summary>Once per settled selection, including handoff and cancellation; after any launch notification.</summary>
        public event Action<PropGrabInteractable, Transform> Released;

        // Who held, threw or passed the prop, and when.
        object holder, thrownBy, guarded;
        float thrownAt = float.NegativeInfinity, guardedAt = float.NegativeInfinity;
        int exitFrame = -1;
        float nearEaseIn;
        static readonly List<PropGrabInteractable> thrown = new List<PropGrabInteractable>();

        public float ThrownAt => thrownAt;
        /// <summary>The last throwing hand, or its interactor if there was no <see cref="PlayerHand"/>.</summary>
        public object ThrownBy => thrownBy;
        public static IReadOnlyList<PropGrabInteractable> RecentlyThrown
        {
            get
            {
                var now = Time.time;
                thrown.RemoveAll(p => !p || p.isSelected || !HandOffRules.InCatchWindow(p.thrownAt, now));
                return thrown;
            }
        }

        /// <summary>Controller and tracked interactors on the same side count as one hand.</summary>
        public static object HandOf(IXRSelectInteractor interactor)
        {
            if (interactor == null) return null;
            var hand = PlayerHand.Of(interactor.transform);
            return hand ? (object)hand : interactor;
        }

        static readonly List<PropGrabInteractable> all = new List<PropGrabInteractable>();
        /// <summary>Enabled candidates for host-owned distance grabs.</summary>
        public static IReadOnlyList<PropGrabInteractable> All => all;

        protected override void OnEnable()
        {
            base.OnEnable();
            all.Add(this);
        }

        protected override void OnDisable()
        {
            all.Remove(this);
            thrown.Remove(this);
            base.OnDisable(); // may cancel a selection and settle a release during teardown
            if (lateRelease != null) CancelLateRelease();
            if (releaseUnannounced)
            {
                ClearReleaseVelocity();
                NotifyRelease(committed: false);
            }
        }

        protected override void Awake()
        {
            base.Awake();
            body = GetComponent<Rigidbody>();
            // XRI exits the old selection before entering the new one, and skips Detach while selected.
            selectMode = InteractableSelectMode.Single;
        }

        void Guard(object hand)
        {
            guarded = hand;
            guardedAt = Time.time;
        }

        public override bool IsSelectableBy(IXRSelectInteractor interactor)
        {
            if (GameplayPaused || !base.IsSelectableBy(interactor) || HeldElsewhere(interactor)) return false;
            return !HandOffRules.Guarded(guarded, guardedAt, HandOf(interactor), Time.time);
        }

        public override bool IsHoverableBy(IXRHoverInteractor interactor) =>
            base.IsHoverableBy(interactor) && !HeldElsewhere(interactor);

        bool HeldElsewhere(IXRInteractor interactor) =>
            isSelected && !(interactor is IXRSelectInteractor s && IsSelected(s)) && IsFar(interactor, this);

        public static bool IsFar(IXRInteractor interactor, PropGrabInteractable prop)
        {
            if (interactor == null || !prop || !interactor.transform) return false;
            return Reach(interactor.transform.position, prop) > (prop.GetComponent<IDistanceGrab>()?.NearReach ?? DefaultNearReach);
        }

        protected override void OnSelectEntering(SelectEnterEventArgs args)
        {
            if (lateRelease != null) CancelLateRelease();
            // The outgoing selection settles before the incoming hand takes custody, without launching.
            NotifyRelease(committed: false);
            Grabbing?.Invoke(this);
            Launched = false;
            haveRelease = false;
            ReleaseSource = null;
            releaseLinear = releaseAngular = Vector3.zero;
            thrown.Remove(this);
            var to = HandOf(args.interactorObject);
            if (exitFrame == Time.frameCount && holder != null && !ReferenceEquals(holder, to)) Guard(holder);
            hand = PlayerHand.Of(args.interactorObject.transform);
            if (hand) hand.Sync();
            motion = ControllerMotion.Of(args.interactorObject.transform);
            if (!hand && motion) hand = motion.hand;
            heldGripMode = GripMode;
            rig.Track(motion ? motion.transform.parent : hand ? hand.transform.parent : null);
            visual = (hand ? hand.Visual as IHeldVisual ?? hand.GetComponentInChildren<IHeldVisual>() : null)
                ?? args.interactorObject.transform.GetComponentInParent<IHeldVisual>();
            var attach = args.interactorObject.GetAttachTransform(this);
            nearEaseIn = attachEaseInTime;
            originalAttach = attachTransform;
            originalDynamicAttach = useDynamicAttach;
            var distance = GetComponent<IDistanceGrab>();
            if (distance != null && (IsFar(args.interactorObject, this) || attach && Reach(attach.position, this) > distance.NearReach))
                attachEaseInTime = Mathf.Max(0f, distance.EaseInTime(args.interactorObject));
            if (!PlaceInHand(attach) && !originalAttach) useDynamicAttach = true;
            base.OnSelectEntering(args);
            if (visual != null) visual.GripChanged += RefitGrip;
        }

        /// <summary>Distance to the prop's colliders (centre of mass if it has none).</summary>
        static float Reach(Vector3 from, PropGrabInteractable prop)
        {
            if (XRInteractableUtility.TryGetClosestPointOnCollider(prop, from, out var info)) return Vector3.Distance(from, info.point);
            return Vector3.Distance(from, prop.body ? prop.body.worldCenterOfMass : prop.transform.position);
        }

        public void RefitGrip()
        {
            if (!isSelected || !PlaceInHand(interactorsSelecting[0].GetAttachTransform(this))) return;
            // XRI's transformers cache the object-to-attach offset on grab. Refresh without reselecting.
            for (var i = 0; i < singleGrabTransformersCount; i++) GetSingleGrabTransformerAt(i).OnGrab(this);
            for (var i = 0; i < multipleGrabTransformersCount; i++) GetMultipleGrabTransformerAt(i).OnGrab(this);
        }

        bool PlaceInHand(Transform interactorAttach)
        {
            if (visual == null || visual is UnityEngine.Object obj && !obj || !interactorAttach ||
                GetComponent<IGripSource>() == null || !visual.TryGetGripFrame(out var model, out var knuckles) || !model)
                return false;
            if (!gripAttach)
            {
                gripAttach = new GameObject("GripAttach").transform;
                gripAttach.SetParent(transform, false);
            }
            var right = hand ? hand.RightHand : !motion || motion.rightHand;
            var spec = CurrentGripFor(right);
            var held = visual.FitGrip(this, spec, GripPlacement.PropPose(model, knuckles, spec));
            held = GripAdjustmentMath.Apply(held, GripAdjustmentMath.WorldFrame(model), spec.center, GripAdjustment, right);
            // The prop's pose relative to the interactor's attach point, expressed as the prop's own attach point.
            var inv = Quaternion.Inverse(held.rotation);
            gripAttach.localPosition = inv * (interactorAttach.position - held.position);
            gripAttach.localRotation = inv * interactorAttach.rotation;
            attachTransform = gripAttach;
            useDynamicAttach = false;
            visual.Hold(this, spec, held);
            return true;
        }

        Vector3 HeldCenter(Transform interactorAttach, IXRSelectInteractor interactor)
        {
            var point = GetAttachTransform(interactor);
            if (!interactorAttach || !point) return body.worldCenterOfMass;
            var rotation = Quaternion.Inverse(transform.rotation);
            return PropThrow.HeldCenter(new Pose(interactorAttach.position, interactorAttach.rotation),
                new Pose(rotation * (point.position - transform.position), rotation * point.rotation),
                rotation * (body.worldCenterOfMass - transform.position));
        }

        protected override void OnSelectExiting(SelectExitEventArgs args)
        {
            // The manager can exit before ProcessInteractable carries this frame's rig move.
            CarryWithRig();
            haveRelease = false;
            var canceled = args.isCanceled || GameplayPaused || modeDrop || heldGripMode != GripMode || !isActiveAndEnabled;
            var interactor = args.interactorObject;
            releaseInteractor = interactor.transform;
            var candidate = default(LateRelease);
            if (!canceled && throwOnDetach && motion && motion.isActiveAndEnabled)
            {
                motion.SampleThisFrame();
                if (motion.Release(Time.time, out var peak) && (!hand || hand.Present || peak.Source == ThrowSources.HandPalm))
                {
                    var lever = HeldCenter(interactor.GetAttachTransform(this), interactor) - motion.transform.position;
                    SampleRelease(peak, lever);
                    var latest = motion.History.Latest;
                    var previous = motion.History.Previous;
                    if (heldGripMode == HandMode.Controller && latest.Source != ThrowSources.HandPalm && latest.Time == Time.time &&
                        latest.Linear.magnitude > previous.Linear.magnitude)
                    {
                        candidate = new LateRelease(Time.time, latest.Linear, previous.Linear.magnitude);
                        latePeak = peak;
                        lateLever = lever;
                    }
                }
            }
            if (visual != null)
            {
                var outgoing = visual;
                visual = null;
                outgoing.GripChanged -= RefitGrip;
                if (!(outgoing is UnityEngine.Object obj) || obj) outgoing.Release(this);
            }
            holder = HandOf(interactor);
            releaseUnannounced = true;
            exitFrame = Time.frameCount;
            base.OnSelectExiting(args);
            attachTransform = originalAttach;
            useDynamicAttach = originalDynamicAttach;
            attachEaseInTime = nearEaseIn;
            if (canceled) ClearReleaseVelocity();
            else if (candidate != null && candidate.ShouldWait(Time.time) && !body.isKinematic && releaseInteractor)
            {
                lateRelease = candidate;
                lateOpenedAt = Time.time;
                lateAttach = releaseInteractor;
                lateLastPosition = body.position;
                var inv = Quaternion.Inverse(lateAttach.rotation);
                lateLeverLocal = inv * lateLever;
                lateLocalPosition = inv * (body.position - lateAttach.position);
                lateLocalRotation = inv * body.rotation;
                lateKinematic = body.isKinematic;
                lateGravity = body.useGravity;
                body.isKinematic = true;
                body.useGravity = false;
            }
        }

        protected override void OnSelectExited(SelectExitEventArgs args)
        {
            base.OnSelectExited(args);
            if (!isSelected && (args.isCanceled || GameplayPaused || modeDrop || heldGripMode != GripMode || !isActiveAndEnabled))
                NotifyRelease(committed: false);
        }

        /// <summary>Apply the kit release in place of XRI's smoothing and gaze assist. Not called on a pass.</summary>
        protected override void Detach()
        {
            if (lateRelease != null || !releaseUnannounced) return;
            if (heldGripMode != GripMode)
            {
                ClearReleaseVelocity();
                NotifyRelease(committed: false);
                return;
            }
            Launch();
        }

        public override void ProcessInteractable(XRInteractionUpdateOrder.UpdatePhase updatePhase)
        {
            if (GameplayPaused) return;
            if ((isSelected || lateRelease != null) && heldGripMode != GripMode) DropForModeChange();
            // Carry before XRI's velocity tracking can chase a teleport across the gap.
            if (isSelected && (updatePhase == XRInteractionUpdateOrder.UpdatePhase.Dynamic || updatePhase == XRInteractionUpdateOrder.UpdatePhase.Fixed))
                CarryWithRig();
            base.ProcessInteractable(updatePhase);
        }

        void CarryWithRig()
        {
            if (!rig.Moved(out var carry)) return;
            var pose = carry.Carry(new Pose(body.position, body.rotation));
            var visualPose = carry.Carry(new Pose(transform.position, transform.rotation));
            transform.SetPositionAndRotation(visualPose.position, visualPose.rotation);
            body.position = pose.position;
            body.rotation = pose.rotation;
            if (!body.isKinematic)
            {
                body.linearVelocity = carry.Rotation * body.linearVelocity;
                body.angularVelocity = carry.Rotation * body.angularVelocity;
            }
            if (isSelected) SetTargetPose(carry.Carry(GetTargetPose()));
            lateLastPosition = carry.Point(lateLastPosition);
            if (lateRelease != null)
            {
                // The deadline branch can finish without updating the attach pose again.
                var turn = carry.Rotation;
                latePeak = new ThrowSample(latePeak.Time, turn * latePeak.Linear, turn * latePeak.Angular, latePeak.Source);
                lateLever = turn * lateLever;
                releaseLinear = turn * releaseLinear;
                releaseAngular = turn * releaseAngular;
                lateRelease.Rotate(turn);
            }
            CarriedByRig?.Invoke(carry);
        }

        void LateUpdate()
        {
            if (GameplayPaused || lateRelease == null) return;
            if (heldGripMode != GripMode || !lateAttach || hand && !hand.Present) { DropForModeChange(); return; }
            CarryWithRig(); // keep the ride's sweep off the rig relocation gap
            if (lateRelease == null) return;
            // A hitch may already have recorded a new frame. Do not admit an over-budget sample.
            if (!lateRelease.ShouldWait(Time.time)) { FinishLateRelease(); return; }
            if (motion && motion.isActiveAndEnabled)
            {
                motion.SampleThisFrame();
                var sample = motion.History.Latest;
                if (sample.Time > lateOpenedAt && sample.Time - lateOpenedAt < LateRelease.Max)
                {
                    lateRelease.Add(sample.Time, sample.Linear);
                    if (motion.Release(sample.Time, out var peak)) latePeak = peak;
                }
            }
            var position = lateAttach.position + lateAttach.rotation * lateLocalPosition;
            var rotation = lateAttach.rotation * lateLocalRotation;
            // Sweep before moving: an impact ends the ride at the speed observed so far.
            var travel = position - lateLastPosition;
            if (travel.sqrMagnitude > 1e-8f && body.SweepTest(travel.normalized, out _, travel.magnitude, QueryTriggerInteraction.Ignore))
            {
                FinishLateRelease();
                return;
            }
            body.position = position;
            body.rotation = rotation;
            lateLastPosition = position;
            lateLever = lateAttach.rotation * lateLeverLocal;
            if (!lateRelease.ShouldWait(Time.time)) FinishLateRelease();
        }

        void CancelLateRelease()
        {
            lateRelease.Cancel();
            lateRelease = null;
            body.isKinematic = lateKinematic;
            body.useGravity = lateGravity;
            lateAttach = null;
        }

        /// <summary>A scripted owner claims the prop during follow-through. That owner controls kinematic state.</summary>
        public void CancelLateReleaseForOwner()
        {
            if (lateRelease == null) return;
            lateRelease.Cancel();
            lateRelease = null;
            lateAttach = null;
            body.useGravity = lateGravity;
            haveRelease = false;
            ReleaseSource = null;
            releaseLinear = releaseAngular = Vector3.zero;
            NotifyRelease(committed: false);
        }

        /// <summary>End the brief ride early on a collision; only the first completion can launch.</summary>
        public void FinishLateRelease()
        {
            if (lateRelease == null || GameplayPaused) return;
            if (heldGripMode != GripMode || !lateAttach || hand && !hand.Present) { DropForModeChange(); return; }
            CarryWithRig();
            if (lateRelease == null) return;
            var best = lateRelease.Peak;
            var peak = latePeak;
            CancelLateRelease();
            // Keep ThrowHistory's aim/reversal rules while retaining the observed speed in a release-frame hitch.
            if (best.magnitude > peak.Linear.magnitude && Vector3.Dot(best, peak.Linear) > 0f)
                peak = new ThrowSample(peak.Time, peak.Linear.normalized * best.magnitude, peak.Angular, peak.Source);
            SampleRelease(peak, lateLever);
            Launch();
        }

        void SampleRelease(ThrowSample peak, Vector3 lever)
        {
            releaseLinear = PropThrow.Launch(peak, lever);
            releaseAngular = PropThrow.Angular(peak.Angular);
            ReleaseSource = peak.Source ?? ControllerMotion.FrameDelta;
            haveRelease = true;
        }

        void Launch()
        {
            if (!releaseUnannounced || isSelected) return;
            Guard(holder);
            if (!throwOnDetach || body.isKinematic)
            {
                releaseLinear = releaseAngular = Vector3.zero;
                NotifyRelease();
                return;
            }
            if (!haveRelease)
            {
                // No trustworthy sample from a configured hand: drop, not a body-tracking fling.
                if (hand || motion || heldGripMode == HandMode.TrackedHand) ClearReleaseVelocity();
                else
                {
                    releaseLinear = PropThrow.Linear(body.linearVelocity / PropThrow.VelocityScale);
                    releaseAngular = PropThrow.Angular(body.angularVelocity);
                    ReleaseSource = "body";
                }
            }
            else releaseLinear = ThrowAssist.ApplyMoving(body.worldCenterOfMass, releaseLinear, Gravity, out _);
            // Controllers keep their pre-assist cap; hands alone are capped again after assist.
            var tracked = ReleaseSource == ThrowSources.HandPalm || heldGripMode == HandMode.TrackedHand;
            releaseLinear = PropThrow.Bound(releaseLinear, tracked ? ThrowTuning.TopSpeed : float.MaxValue);
            releaseAngular = PropThrow.Bound(releaseAngular, PropThrow.MaxAngularSpeed);
            body.linearVelocity = releaseLinear;
            body.angularVelocity = releaseAngular;
            Launched = releaseLinear.sqrMagnitude >= PropHitFilter.MinSpeed * PropHitFilter.MinSpeed;
            if (Launched)
            {
                thrownBy = holder;
                thrownAt = Time.time;
                if (!thrown.Contains(this)) thrown.Add(this);
            }
            NotifyRelease();
        }

        void NotifyRelease(bool committed = true)
        {
            if (!releaseUnannounced) return;
            releaseUnannounced = false;
            var from = releaseInteractor;
            releaseInteractor = null;
            rig.Track(null);
            if (committed)
            {
                ReleaseSequence++;
                LaunchedFromHand?.Invoke();
            }
            Released?.Invoke(this, from);
        }
    }
}
