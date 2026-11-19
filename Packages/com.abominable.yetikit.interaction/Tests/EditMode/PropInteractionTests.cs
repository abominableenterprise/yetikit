using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.XR.Hands;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using YetiKit.Hands;

namespace YetiKit.Interaction.Tests
{
    public class PropInteractionTests
    {
        GameObject scene;
        XRInteractionManager manager;
        PropGrabInteractable grab;
        GrabbableProp prop;

        [TearDown]
        public void TearDown()
        {
            if (scene) Object.DestroyImmediate(scene);
        }

        [UnityTest]
        public IEnumerator SetDownDoesNotThrowOrReleaseTwice()
        {
            yield return new EnterPlayMode();
            Build();
            var hand = Controller(out var motion);
            Select(hand);
            ProcessLate();
            Assert.That(prop.Held, Is.True);
            Assert.That(grab.ReleaseSequence, Is.Zero);

            SeedController(motion, 0f, 0f);
            Exit(hand);
            ProcessLate();
            ProcessLate();
            Assert.That(prop.Held, Is.False);
            Assert.That(grab.PendingLateRelease, Is.False);
            Assert.That(grab.ReleaseSequence, Is.EqualTo(1));
            Assert.That(grab.Launched, Is.False);
            Assert.That(prop.Body.linearVelocity, Is.EqualTo(Vector3.zero));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator EarlyGripOpenCommitsOnlyOneLaunch()
        {
            yield return new EnterPlayMode();
            Build();
            var hand = Controller(out var motion);
            Select(hand);
            SeedController(motion, 1f, 4f);
            Exit(hand);
            Assert.That(grab.PendingLateRelease, Is.True);
            Assert.That(grab.ReleaseSequence, Is.Zero);

            grab.FinishLateRelease();
            grab.FinishLateRelease();
            ProcessLate();
            ProcessLate();
            Assert.That(grab.PendingLateRelease, Is.False);
            Assert.That(grab.ReleaseSequence, Is.EqualTo(1));
            Assert.That(grab.Launched, Is.True);
            Assert.That(prop.Body.linearVelocity.x, Is.GreaterThan(2f));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator SameFrameHandOffDoesNotLaunchFromGivingHand()
        {
            yield return new EnterPlayMode();
            Build();
            var from = Controller(out var motion);
            var to = Controller(out _);
            Select(from);
            SeedController(motion, 1f, 4f);
            Select(to);
            ProcessLate();
            Assert.That(from.hasSelection, Is.False);
            Assert.That(to.hasSelection && prop.Held, Is.True);
            Assert.That(grab.PendingLateRelease, Is.False);
            Assert.That(grab.ReleaseSequence, Is.Zero);
            Assert.That(grab.Launched, Is.False);
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator TrackingLossWithoutPalmMotionCannotThrow()
        {
            yield return new EnterPlayMode();
            Build();
            var root = Child("Hand");
            var hand = root.AddComponent<PlayerHand>();
            var tracking = new PalmTracking();
            hand.Tracking = tracking;
            var motion = root.AddComponent<ControllerMotion>();
            motion.hand = hand;
            var near = Child("Near", root.transform);
            near.AddComponent<SphereCollider>().isTrigger = true;
            var interactor = near.AddComponent<HandGrabInteractor>();
            interactor.interactionManager = manager;
            hand.grabber = interactor;
            hand.Tick(Time.time);
            Assert.That(hand.Mode, Is.EqualTo(HandMode.TrackedHand));
            Select(interactor);
            motion.Sample(Time.time - 0.01f, 0.01f);
            motion.Sample(Time.time, 0.01f);
            tracking.Tracked = false;
            hand.Tick(Time.time + HandGrabGesture.LostGrace + 0.01f);
            hand.Tick(Time.time + HandGrabGesture.LostGrace * 2f + 0.02f);
            ProcessLate();
            Assert.That(prop.Held, Is.False);
            Assert.That(grab.ReleaseSequence, Is.Zero, "tracking cancellation is not a committed launch");
            Assert.That(prop.Body.linearVelocity, Is.EqualTo(Vector3.zero));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator PalmSamplingUsesPalmNotWristAndIgnoresRigTranslation()
        {
            yield return new EnterPlayMode();
            Build();
            var root = Child("Hand");
            var hand = root.AddComponent<PlayerHand>();
            var tracking = new PalmTracking();
            hand.Tracking = tracking;
            var motion = root.AddComponent<ControllerMotion>();
            motion.hand = hand;
            hand.Tick(1f);
            motion.Sample(1f, 0.01f);
            tracking.Palm = Vector3.right * 0.03f;
            hand.Tick(1.01f);
            motion.Sample(1.01f, 0.01f);
            Assert.That(motion.History.Latest.Source, Is.EqualTo(ThrowSources.HandPalm));
            Assert.That(motion.History.Latest.Linear.x, Is.EqualTo(3f).Within(0.001f));

            scene.transform.position += Vector3.forward * 10f;
            motion.Sample(1.02f, 0.01f);
            Assert.That(motion.History.Latest.Linear.magnitude, Is.LessThan(0.001f));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator ProfilesResolveByModeAndPreserveNullThroughSerialization()
        {
            yield return new EnterPlayMode();
            Build();
            prop.handed = true;
            var handGrip = new GripSpec(GripKind.Pinch, Vector3.forward, Vector3.up, Vector3.one, 0.01f);
            prop.gripProfiles.hand = new GripProfile("specific", handGrip);
            var json = JsonUtility.ToJson(prop);
            prop.gripProfiles = new GripProfiles { controller = new GripProfile("unused", handGrip) };
            JsonUtility.FromJsonOverwrite(json, prop);

            Assert.That(prop.gripProfiles.controller, Is.Null);
            Assert.That(prop.GripFor(true, HandMode.Controller).kind, Is.EqualTo(prop.grip.kind));
            Assert.That(prop.GripFor(true, HandMode.None).center, Is.EqualTo(prop.grip.center));
            Assert.That(prop.GripFor(true, HandMode.TrackedHand).kind, Is.EqualTo(GripKind.Pinch));
            Assert.That(prop.GripFor(false, HandMode.TrackedHand).palm, Is.EqualTo(-Vector3.up));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator LoosePropReturnsAfterStayingOutsideConfiguredArea()
        {
            yield return new EnterPlayMode();
            Build();
            var settings = PropRespawnSettings.Default;
            settings.AreaRadius = 1f;
            settings.OutOfAreaSeconds = 1f;
            prop.RespawnSettings = settings;
            var startingRevision = prop.MotionRevision;
            prop.transform.position = Vector3.forward * 2f;
            prop.Tick(1f, 0.5f);
            Assert.That(prop.transform.position, Is.Not.EqualTo(prop.Home));
            prop.Tick(1.5f, 0.5f);
            Assert.That(prop.transform.position, Is.EqualTo(prop.Home));
            Assert.That(prop.MotionRevision, Is.EqualTo(startingRevision + 1));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator ThrownHitSinkGetsOneImpactAndRawContactsAreIndependent()
        {
            yield return new EnterPlayMode();
            Build();
            var hand = Controller(out var motion);
            var obstacle = Child("Obstacle").AddComponent<BoxCollider>();
            var target = Child("Eligible target").AddComponent<BoxCollider>();
            var sink = new HitSink(target);
            prop.HitSink = sink;
            prop.LaunchedPropContacted += sink.OnContact;
            var point = Vector3.forward;
            var relative = Vector3.left * 5f;
            Assert.That(prop.Collided(target, relative, point, Time.time), Is.False);
            Select(hand);
            SeedController(motion, 4f, 4f);
            Exit(hand);
            ProcessLate();
            Assert.That(grab.Launched, Is.True);
            Assert.That(prop.Collided(obstacle, relative, point, Time.time), Is.False);
            Assert.That(prop.Collided(target, relative, point, Time.time), Is.True);
            Assert.That(prop.Collided(target, relative, point, Time.time), Is.False);
            Assert.That(sink.Contacts, Is.EqualTo(3));
            Assert.That(sink.Hits, Is.EqualTo(1));
            Assert.That(sink.Last.Target, Is.SameAs(target));
            Assert.That(sink.Last.Point, Is.EqualTo(point));
            Assert.That(sink.Last.Direction, Is.EqualTo(-relative));
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator CompoundPropIgnoresNeighboursWithEverySolidCollider()
        {
            yield return new EnterPlayMode();
            Build(compound: true);
            var solids = prop.GetComponentsInChildren<BoxCollider>();
            var neighbour = Child("Neighbour");
            neighbour.transform.position = Vector3.right * 0.1f;
            var other = neighbour.AddComponent<BoxCollider>();
            neighbour.AddComponent<Rigidbody>().useGravity = false;
            neighbour.AddComponent<GrabbableProp>();
            Physics.SyncTransforms();
            Select(Controller(out _));
            Assert.That(solids.Length, Is.EqualTo(2));
            foreach (var solid in solids) Assert.That(Physics.GetIgnoreCollision(solid, other), Is.True);
            prop.enabled = false;
            foreach (var solid in solids) Assert.That(Physics.GetIgnoreCollision(solid, other), Is.False);
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator HeldLayerRestoresMixedHierarchyAfterGraceAndDisable()
        {
            yield return new EnterPlayMode();
            Build(compound: true);
            var heldLayer = LayerMask.NameToLayer(HeldLayer.LayerName);
            Assert.That(heldLayer, Is.GreaterThan(0));
            var child = prop.transform.GetChild(0).gameObject;
            var childLayer = LayerMask.NameToLayer("Ignore Raycast");
            for (var pass = 0; pass < 2; pass++)
            {
                var hand = Controller(out _);
                child.layer = childLayer;
                Select(hand);
                Assert.That(prop.Held, Is.True);
                Assert.That(prop.gameObject.layer, Is.EqualTo(heldLayer));
                Assert.That(child.layer, Is.EqualTo(heldLayer));
                if (pass == 0)
                {
                    Exit(hand);
                    ProcessLate();
                    prop.Tick(Time.time + HeldLayer.Grace + 0.01f, 0f);
                }
                else prop.enabled = false;
                Assert.That(prop.gameObject.layer, Is.Zero);
                Assert.That(child.layer, Is.EqualTo(childLayer));
            }
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator ScaledGripAttachMatchesFittedPoseOnGrabAndRefit()
        {
            yield return new EnterPlayMode();
            Build();
            prop.transform.localScale = new Vector3(2f, 3f, 0.5f);
            prop.transform.rotation = Quaternion.Euler(15f, 30f, 45f);
            var hand = Controller(out _);
            var visual = hand.gameObject.AddComponent<FittedGripVisual>();
            Select(hand);
            AssertFittedAttach();
            visual.Offset *= 2f;
            visual.Refit();
            AssertFittedAttach();
            yield return new ExitPlayMode();

            void AssertFittedAttach()
            {
                var attach = hand.GetAttachTransform(grab);
                var pose = visual.Held;
                var offset = Quaternion.Inverse(prop.transform.rotation) * (grab.attachTransform.position - prop.transform.position);
                Assert.That(Vector3.Distance(pose.position + pose.rotation * offset, attach.position), Is.LessThan(0.0001f));
            }
        }

        void Build(bool compound = false)
        {
            scene = new GameObject("Synthetic interaction");
            manager = scene.AddComponent<XRInteractionManager>();
            var body = Child("Prop");
            if (compound)
            {
                Child("First solid", body.transform).AddComponent<BoxCollider>().size = Vector3.one * 0.05f;
                Child("Second solid", body.transform).AddComponent<BoxCollider>().size = Vector3.one * 0.05f;
            }
            else body.AddComponent<BoxCollider>();
            body.AddComponent<Rigidbody>().useGravity = false;
            grab = body.AddComponent<PropGrabInteractable>();
            grab.interactionManager = manager;
            grab.movementType = XRBaseInteractable.MovementType.VelocityTracking;
            prop = body.AddComponent<GrabbableProp>();
        }

        XRDirectInteractor Controller(out ControllerMotion motion)
        {
            var root = Child("Controller");
            motion = root.AddComponent<ControllerMotion>();
            root.AddComponent<SphereCollider>().isTrigger = true;
            var hand = root.AddComponent<XRDirectInteractor>();
            hand.interactionManager = manager;
            return hand;
        }

        static void SeedController(ControllerMotion motion, float previous, float latest)
        {
            motion.SampleThisFrame();
            motion.History.Clear();
            motion.History.Add(new ThrowSample(Time.time - 0.01f, Vector3.right * previous, Vector3.zero, ControllerMotion.FrameDelta));
            motion.History.Add(new ThrowSample(Time.time, Vector3.right * latest, Vector3.zero, ControllerMotion.FrameDelta));
        }

        void Select(IXRSelectInteractor hand) => manager.SelectEnter(hand, grab);
        void Exit(IXRSelectInteractor hand) => manager.SelectExit(hand, grab);
        void ProcessLate() => grab.ProcessInteractable(XRInteractionUpdateOrder.UpdatePhase.Late);

        GameObject Child(string name, Transform parent = null)
        {
            var child = new GameObject(name);
            child.transform.SetParent(parent ? parent : scene.transform, false);
            return child;
        }

        public sealed class FittedGripVisual : MonoBehaviour, IHeldVisual
        {
            public Pose Held;
            public Vector3 Offset = new Vector3(0.1f, 0.2f, 0.05f);
            public event System.Action GripChanged;
            public void Refit() => GripChanged?.Invoke();
            public bool TryGetGripFrame(out Transform model, out Vector3 knuckles)
            {
                model = transform;
                knuckles = Vector3.zero;
                return true;
            }
            public Pose FitGrip(PropGrabInteractable prop, GripSpec grip, Pose authoredPose) =>
                new Pose(transform.position + Offset, Quaternion.Euler(10f, 20f, 35f));
            public void Hold(PropGrabInteractable prop, GripSpec grip, Pose heldPose) => Held = heldPose;
            public void Release(PropGrabInteractable prop) { }
        }

        sealed class PalmTracking : IHandTracking, IHandJointPoses
        {
            public bool Tracked = true;
            public Vector3 Palm;

            public bool TryGetHand(bool right, Vector3[] points, out Pose wrist)
            {
                wrist = Pose.identity;
                for (var i = 0; i < points.Length; i++) points[i] = Vector3.forward * (i * 0.01f);
                return Tracked;
            }

            public bool TryGetJointPoses(bool right, Pose[] poses)
            {
                for (var i = 0; i < poses.Length; i++) poses[i] = Pose.identity;
                poses[XRHandJointID.Palm.ToIndex()] = new Pose(Palm, Quaternion.identity);
                return Tracked;
            }
        }

        sealed class HitSink : IThrownHitSink
        {
            readonly Collider target;
            public int Hits, Contacts;
            public PropHit Last;

            public HitSink(Collider target) => this.target = target;
            public void OnContact(GrabbableProp prop, Collider collider) => Contacts++;
            public Component ResolveTarget(Collider collider) => collider == target ? target : null;
            public void OnHit(in PropHit hit) { Last = hit; Hits++; }
        }
    }
}
