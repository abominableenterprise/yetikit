using YetiKit.Hands;
using UnityEngine;
using UnityEngine.InputSystem;

namespace YetiKit.Interaction
{
    /// <summary>
    /// One controller's recent motion for throwing (on the controller transform, under the XR Origin's Camera Offset).
    /// Every frame records the tracked device velocity and angular velocity (tracking space, turned into world space
    /// by the Camera Offset) from the first of <see cref="VelocityPaths"/> / <see cref="AngularPaths"/> that is bound
    /// and reporting, or, without one (editor, simulator, tracking loss), the finite difference of this transform
    /// within the Camera Offset (so moving the rig is not hand motion). <see cref="Release"/> gives the peak of the
    /// last few frames (<see cref="ThrowHistory"/>), with the source it came from.
    /// </summary>
    public sealed class ControllerMotion : MonoBehaviour
    {
        public const float MinTrackedSpeed = 0.01f; // below this the device velocity counts as missing
        public const string FrameDelta = "frame delta";
        /// <summary>The source of a tracked hand's samples: the hand root's (palm's) filtered frame delta.</summary>
        public const string HandPalm = ThrowSources.HandPalm;

        /// <summary>
        /// The device velocity controls, best first. XR controller layouts may expose velocity through
        /// the device or pointer pose, or directly on the device. {hand} is {RightHand} or {LeftHand}.
        /// </summary>
        public static readonly string[] VelocityPaths =
        {
            "<XRController>{hand}/devicePose/velocity",
            "<XRController>{hand}/deviceVelocity",
            "<XRController>{hand}/pointer/velocity",
        };

        public static readonly string[] AngularPaths =
        {
            "<XRController>{hand}/devicePose/angularVelocity",
            "<XRController>{hand}/deviceAngularVelocity",
            "<XRController>{hand}/pointer/angularVelocity",
        };

        /// <summary>Hand mode: a palm step faster than this (m/s over its frame) is a tracking snap, not hand motion: it is
        /// never sampled, the root's new pose is the new baseline. A hard overhand throw's wrist peaks around 8-10 m/s
        /// (11-14 cm a frame at 72 Hz); a snap (the hand re-fitted 20+ cm away in one frame) reads 15 m/s and up.
        /// Smaller glitches are single spiked frames: the release's trimmed window mean drops them (ThrowHistory).</summary>
        public const float MaxHandStep = ThrowSources.MaxHandStep;

        public bool rightHand = true;
        [Tooltip("The hand root this lives on: with a tracked hand the velocity is the root's filtered motion.")]
        public PlayerHand hand;
        [Tooltip("Hand mode: the release velocity is each frame's mean over this many seconds before it, an isolated spike "
            + "left out (tracked palms are noisier than controllers). 0: off. Controller throws never use it.")]
        [Range(0f, 0.1f)] public float handReleaseWindow = DefaultHandReleaseWindow;
        // The scene still serialises the old 0.06 s: the release always uses the code's window (no scene change needed).
        // A shorter positive window is raised to MinHandReleaseWindow, so the 3-frame rule always has its frames (#166).
        float ReleaseWindow => HandWindow(handReleaseWindow);

        /// <summary>The hand release window used for an inspector value <paramref name="window"/>: at most
        /// <see cref="DefaultHandReleaseWindow"/>, at least <see cref="MinHandReleaseWindow"/> when positive (0: off).</summary>
        public static float HandWindow(float window) =>
            window <= 0f ? 0f : Mathf.Clamp(window, MinHandReleaseWindow, DefaultHandReleaseWindow);

        /// <summary>s: the shortest usable positive hand window, 3 frames at 72 Hz (the frame and the two before it, 0,
        /// 13.9 and 27.8 ms back, the 4th at 41.7 ms safely out). A shorter one (0.02 s holds 2 frames) leaves no frame
        /// with <see cref="ThrowHistory.MinSmoothFrames"/>, so every swing released as a drop (#166). A full 3/72 s
        /// (41.7 ms) would sit on the 4th frame's edge and exceed the default, so the minimum is the default's 40 ms.</summary>
        public const float MinHandReleaseWindow = 0.04f;

        /// <summary>s: 3 frames at 72 Hz, so each frame's smoothed value is the per-axis median of itself and the two
        /// before it. A single spiked frame or an out-and-back pair is never the median; a real swing's peak is (throws-1028:
        /// the 60 ms trimmed mean averaged in the still-accelerating frames and read a real 9 m/s peak as 8).</summary>
        public const float DefaultHandReleaseWindow = 0.04f;

        readonly ThrowHistory history = new ThrowHistory();
        InputAction[] velocity, angular;
        Vector3 lastPosition;
        Quaternion lastRotation;
        bool hasLast, trustedPalmAtLoss, hasPalmBaseline;
        Vector3 palmBaseline; // independently supported position; an isolated accepted step cannot move it
        float PalmToleranceSquared => HandReleaseVelocity.StillSpeed * HandReleaseVelocity.StillSpeed * ReleaseWindow * ReleaseWindow;
        float lastTime;
        int sampledFrame = -1, epoch = -1;
        float lastSnapAt = float.NegativeInfinity;

        public ThrowHistory History => history;
        readonly HandReleaseVelocity handRelease = new HandReleaseVelocity();
        /// <summary>Did the last sample's linear velocity come from the tracked device (else from transform deltas)?</summary>
        public bool Tracked { get; private set; }
        /// <summary>Where the last sample's linear velocity came from: a control path, or <see cref="FrameDelta"/>.</summary>
        public string Source { get; private set; } = FrameDelta;
        /// <summary>Hand-mode frames dropped as tracking snaps (<see cref="MaxHandStep"/>) since start-up.</summary>
        public int Snaps { get; private set; }
        /// <summary>m/s: the fastest raw frame of the last <see cref="Release"/>'s window (the throw log's raw peak).</summary>
        public float RawPeak => history.RawPeak;

        void OnEnable() => Bind();

        /// <summary>Bind the device velocity actions and start a fresh history (OnEnable; edit-mode tests call it).</summary>
        public void Bind()
        {
            OnDisable();
            var hand = rightHand ? "{RightHand}" : "{LeftHand}";
            velocity = Actions("DeviceVelocity", VelocityPaths, hand);
            angular = Actions("DeviceAngularVelocity", AngularPaths, hand);
            ResetAfterPause();
        }

        static InputAction[] Actions(string name, string[] paths, string hand)
        {
            var actions = new InputAction[paths.Length];
            for (var i = 0; i < paths.Length; i++)
            {
                actions[i] = new InputAction($"{name}{i}", InputActionType.Value, paths[i].Replace("{hand}", hand));
                actions[i].Enable();
            }
            return actions;
        }

        void OnDisable()
        {
            Dispose(velocity);
            Dispose(angular);
            velocity = angular = null;
        }

        static void Dispose(InputAction[] actions)
        {
            if (actions != null) foreach (var a in actions) a?.Dispose();
        }

        /// <summary>UI pointing is not a throw wind-up; resume from a fresh motion baseline.</summary>
        public void ResetAfterPause()
        {
            history.Clear();
            handRelease.Clear();
            hasLast = hasPalmBaseline = trustedPalmAtLoss = false;
            sampledFrame = -1;
            lastSnapAt = float.NegativeInfinity;
        }

        // LateUpdate: after tracking and anything else that moved the controller this frame, so the position change
        // and the frame time belong together.
        void LateUpdate() => SampleThisFrame();

        /// <summary>The hand root's <see cref="PlayerHand.PoseEpoch"/> this history belongs to.</summary>
        public int Epoch => epoch;

        /// <summary>
        /// Record this frame now if it has not been yet. The release (XRI's interaction update) comes before
        /// LateUpdate, so without this the release frame's own motion, the newest tracking, would be missing from the
        /// throw; after a hitch (a long frame) that frame is most of the swing.
        /// </summary>
        public void SampleThisFrame() => SampleFrame(Time.frameCount, Time.time, Time.deltaTime);

        /// <summary><see cref="SampleThisFrame"/> for frame <paramref name="frame"/> at <paramref name="now"/> (tests drive
        /// frames with it): once per frame, its dt the real time since the last sample (a hitch's whole length).</summary>
        public void SampleFrame(int frame, float now, float deltaTime)
        {
            if (PropGrabInteractable.GameplayPaused) { ResetAfterPause(); return; }
            if (sampledFrame == frame) return;
            sampledFrame = frame;
            Sample(now, hasLast ? now - lastTime : deltaTime);
            lastTime = now;
        }

        /// <summary>The first action in <paramref name="actions"/> whose control is bound and reporting (null: none).</summary>
        static InputControl Read(InputAction[] actions, out Vector3 value)
        {
            value = Vector3.zero;
            if (actions == null) return null;
            foreach (var a in actions)
            {
                foreach (var c in a.controls)
                {
                    if (c is not InputControl<Vector3> v3 || !c.device.added) continue;
                    var v = v3.ReadValue();
                    if (!Reporting(v)) continue;
                    value = v;
                    return c;
                }
            }
            return null;
        }

        /// <summary>Record this frame (tests call it directly).</summary>
        public void Sample(float now, float dt)
        {
            var reseeded = false;
            if (hand) hand.Sync(); // controller mode: the root on the controller's newest pose (no-op with a tracked hand)
            if (hand && hand.PoseEpoch != epoch)
            {
                // A new pose source (controller ↔ hand, tracking lost or back): the root may jump. A new baseline and no
                // smoothing either way. A new source (a controller, a reacquired hand) also drops the old history and
                // starts with a still frame, so the jump is never a sample. Tracking just lost keeps the history: the
                // root freezes, and a fast throw that loses tracking at the release still throws from it.
                var lost = hand.Mode == HandMode.None;
                // the root now freezes: keep the palm's release velocity from before the loss (HandReleaseVelocity)
                if (lost)
                {
                    trustedPalmAtLoss = hasPalmBaseline && history.Latest.Source == HandPalm &&
                        history.LatestCanPromote(ReleaseWindow) &&
                        (lastPosition - palmBaseline).sqrMagnitude <= PalmToleranceSquared;
                    if (history.Latest.Source == HandPalm) handRelease.TrackingLost(now, history, ReleaseWindow, ReleaseHeadForward);
                }
                else if (hand.Mode == HandMode.Controller)
                {
                    handRelease.Clear();
                    trustedPalmAtLoss = hasPalmBaseline = false;
                }
                else handRelease.TrackingBack(now);
                reseeded = epoch >= 0 && !lost; // the first source at start-up is no switch
                epoch = hand.PoseEpoch;
                hasLast = false;
                if (!lost)
                {
                    history.Clear();
                    // Reacquisition at the old trusted baseline can settle normally. A displaced palm still needs
                    // moving evidence: still samples at a snap's new baseline must not legitimise its return.
                    var stablePalm = trustedPalmAtLoss &&
                        (LocalPosition(hand.HandTracked) - palmBaseline).sqrMagnitude <= PalmToleranceSquared;
                    if (reseeded && hand.HandTracked && !stablePalm) history.Discontinuity();
                    trustedPalmAtLoss = false;
                    lastSnapAt = float.NegativeInfinity;
                }
            }
            // No pose source is active; preserve any trusted pre-loss release without
            // letting inactive device bindings or a frozen root overwrite it.
            if (hand && !hand.Present) return;
            var handMode = hand && hand.HandTracked;
            var space = TrackingSpace;
            var position = LocalPosition(handMode);
            var rotation = LocalRotation(handMode);
            // The fallback: this transform's change within the tracking space (the parent, the Camera Offset), so a
            // teleport or snap turn, which moves the XR Origin and not the hand within it, is never taken for a throw.
            var deltaLin = Vector3.zero;
            var deltaAng = Vector3.zero;
            if (hasLast && dt > 1e-4f)
            {
                var dl = (position - lastPosition) / dt;
                (rotation * Quaternion.Inverse(lastRotation)).ToAngleAxis(out var deg, out var axis);
                if (deg > 180f) deg -= 360f;
                var da = float.IsFinite(axis.x) ? axis * (deg * Mathf.Deg2Rad / dt) : Vector3.zero;
                deltaLin = space ? space.TransformVector(dl) : dl;
                deltaAng = space ? space.TransformDirection(da) : da;
            }
            // The tracked device velocities (tracking space), each used only when it is bound and reporting. A tracked
            // hand has no device velocity here: the hand root's (palm's) frame delta, raw; the release smooths it with a
            // trimmed mean (ThrowHistory). A step faster than any hand (a tracking snap) is dropped: new baseline, no
            // sample, so it never becomes (or, low-pass filtered, smears into) a throw.
            if (handMode && deltaLin.sqrMagnitude > MaxHandStep * MaxHandStep)
            {
                Snaps++;
                history.Discontinuity();
                lastSnapAt = now;
                lastPosition = position;
                lastRotation = rotation;
                return;
            }
            var v = Vector3.zero;
            var w = Vector3.zero;
            var vc = handMode ? null : Read(velocity, out v);
            if (!handMode) Read(angular, out w);
            Tracked = vc != null;
            Source = Tracked ? vc.path : handMode ? HandPalm : FrameDelta;
            var lin = Choose(space ? space.TransformDirection(v) : v, deltaLin);
            var ang = Choose(space ? space.TransformDirection(w) : w, deltaAng);
            // after a reseed the first frame is a still sample (no baseline yet): an immediate release drops, never
            // falls back to the velocity-tracked body that just followed the jump
            if (hasLast || Tracked || reseeded) history.Add(new ThrowSample(now, lin, ang, Source));
            // Keep the last independently supported palm across losses and history clears. Stillness at an
            // isolated jump's displaced position must not make that position a trusted reacquisition baseline.
            if (handMode && (!hasPalmBaseline || history.LatestMotionEstablished ||
                (position - palmBaseline).sqrMagnitude <= PalmToleranceSquared))
            {
                palmBaseline = position;
                hasPalmBaseline = true;
            }
            lastPosition = position;
            lastRotation = rotation;
            hasLast = true;
        }

        /// <summary>The motion of the hand that <paramref name="t"/> (an interactor on a controller, or anything under a
        /// hand root) belongs to: the hand root's, else the nearest one above it.</summary>
        public static ControllerMotion Of(Transform t)
        {
            if (!t) return null;
            var root = PlayerHand.Of(t);
            var m = root ? root.GetComponent<ControllerMotion>() : null;
            return m ? m : t.GetComponentInParent<ControllerMotion>();
        }

        // The hand root follows the wrist, but tracked release estimates use the palm. Keep
        // both pose sources in tracking space so rig translation cannot become throw velocity.
        Transform TrackingSpace => hand ? hand.transform.parent : transform.parent;

        Vector3 LocalPosition(bool trackedHand)
        {
            var world = trackedHand ? hand.PalmPose.position : transform.position;
            var space = TrackingSpace;
            return space ? space.InverseTransformPoint(world) : world;
        }

        Quaternion LocalRotation(bool trackedHand)
        {
            var world = trackedHand ? hand.PalmPose.rotation : transform.rotation;
            var space = TrackingSpace;
            return space ? Quaternion.Inverse(space.rotation) * world : world;
        }

        static bool Reporting(Vector3 v) => v.sqrMagnitude > MinTrackedSpeed * MinTrackedSpeed;

        /// <summary>The tracked velocity when the device reports one (above <see cref="MinTrackedSpeed"/>), else the
        /// frame-delta fallback. Linear and angular choose independently.</summary>
        public static Vector3 Choose(Vector3 tracked, Vector3 fallback) => Reporting(tracked) ? tracked : fallback;

        /// <summary>The release sample (peak of the last few frames); false when nothing recent was recorded.
        /// A tracked hand whose recent frames were all snaps (<see cref="MaxHandStep"/>, a long tracking glitch) has no
        /// fresh sample, but it is still a hand: a still palm release (a drop, never the velocity-tracked body that
        /// followed the snaps at up to the controller cap) while the last snap is under <see cref="ThrowHistory.MaxAge"/> s old.</summary>
        public bool Release(float now, out ThrowSample peak) => Release(now, out peak, true);

        // The XR head camera is world-space, like the recorded palm velocities. Missing head
        // evidence disables the body tiebreaker rather than assuming the rig faces world +z.
        Vector3 ReleaseHeadForward => Camera.main ? Camera.main.transform.forward : Vector3.zero;

        /// <summary><see cref="Release(float, out ThrowSample)"/>; <paramref name="throwing"/> false is the history's peak
        /// as it was before <see cref="HandReleaseVelocity"/> (no release frame, nothing carried over a tracking loss): a
        /// punch's speed on its first frame after a reacquire.</summary>
        public bool Release(float now, out ThrowSample peak, bool throwing)
        {
            // a bare hand (or one that just lost tracking): HandReleaseVelocity; a controller: the history's raw peak
            if (throwing && (history.Latest.Source == HandPalm || handRelease.Carried(now, out _)))
            {
                if (handRelease.Release(now, history, ReleaseWindow, out peak, ReleaseHeadForward)) return true;
            }
            else if (history.Release(now, out peak, history.Latest.Source == HandPalm ? ReleaseWindow : 0f)) return true;
            if (now - lastSnapAt > ThrowHistory.MaxAge && (!throwing || !hand || hand.Present)) return false;
            peak = new ThrowSample(now, Vector3.zero, Vector3.zero, HandPalm);
            return true;
        }
    }
}
