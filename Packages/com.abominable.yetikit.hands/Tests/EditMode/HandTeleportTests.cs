using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;

namespace YetiKit.Hands.Tests
{
    public class HandTeleportTests
    {
        sealed class Tracking : IHandTracking
        {
            public Vector3[] points = Point();

            public bool TryGetHand(bool right, Vector3[] into, out Pose wrist)
            {
                wrist = Pose.identity;
                points.CopyTo(into, 0);
                return true;
            }
        }

        sealed class RecordingProvider : TeleportationProvider
        {
            public int Count { get; private set; }
            public TeleportRequest Last { get; private set; }

            public override bool QueueTeleportRequest(TeleportRequest request)
            {
                Last = request;
                Count++;
                return true;
            }
        }

        static readonly Vector3 Origin = new Vector3(300f, 1.4f, 0f);
        GameObject world;
        RecordingProvider provider;
        HandTeleport teleport;
        Tracking tracking;

        [SetUp]
        public void SetUp()
        {
            world = new GameObject("Test rig and floor");
            provider = world.AddComponent<RecordingProvider>();
            var root = new GameObject("Tracking space").transform;
            root.SetParent(world.transform, false);
            root.position = Origin;
            teleport = AddHand(root, out tracking);
            Assert.That(teleport.TeleportLayerName, Is.EqualTo("Teleport"));
            teleport.TeleportLayerName = "Default";
            var floor = new GameObject("Landing surface");
            floor.transform.SetParent(world.transform, false);
            floor.transform.position = new Vector3(Origin.x, -0.1f, 5f);
            floor.AddComponent<BoxCollider>().size = new Vector3(10f, 0.2f, 12f);
            var area = floor.AddComponent<TeleportationArea>();
            area.interactionLayers = InteractionLayerMask.GetMask("Default");
            area.matchOrientation = MatchOrientation.WorldSpaceUp;
            Physics.SyncTransforms();
        }

        HandTeleport AddHand(Transform space, out Tracking fake)
        {
            var go = new GameObject("Tracked hand");
            go.transform.SetParent(space, false);
            var hand = go.AddComponent<PlayerHand>();
            hand.Tracking = fake = new Tracking();
            var adapter = go.AddComponent<HandTeleport>();
            adapter.hand = hand;
            adapter.provider = provider;
            return adapter;
        }

        [TearDown]
        public void TearDown() => Object.DestroyImmediate(world);

        [Test]
        public void HeldConfirmQueuesExactlyOneRequestAndBlocksGrabUntilRelease()
        {
            Assert.That(Step(0f), Is.False);
            Assert.That(teleport.Aiming, Is.False);
            Assert.That(Step(.32f), Is.False);
            Assert.That(teleport.Aiming && teleport.HasTarget && teleport.hand.GrabBlocked, Is.True);
            var target = teleport.Target.destinationPosition;
            DropThumb();
            Assert.That(Step(.34f), Is.True);
            for (var i = 0; i < 30; i++) Step(.36f + i * .02f);
            Assert.That(provider.Count, Is.EqualTo(1));
            Assert.That(provider.Last.destinationPosition, Is.EqualTo(target));
            Assert.That(provider.Last.requestTime, Is.EqualTo(.34f));
            Assert.That(teleport.Aiming, Is.False);
            Assert.That(teleport.hand.GrabBlocked, Is.True);
            tracking.points = Point();
            Step(1f);
            Assert.That(teleport.hand.GrabBlocked, Is.False);
        }

        [TestCase("pinch")]
        [TestCase("held")]
        [TestCase("ui hover")]
        [TestCase("near UI")]
        [TestCase("UI across arc")]
        public void TakeoverCancelsTeleport(string reason)
        {
            Step(0f);
            Step(.32f);
            Assert.That(teleport.Aiming && teleport.HasTarget, Is.True);
            DropThumb();
            RectTransform panel = null;
            try
            {
                switch (reason)
                {
                    case "pinch": HandGrabTests.Pinch(tracking.points, .01f); break;
                    case "ui hover": teleport.hand.FarInteraction.Hover(this, true); break;
                    case "near UI": panel = RegisterPanel(teleport.hand.Joint(PinchStrength.IndexTip)); break;
                    case "UI across arc": panel = RegisterPanel(Origin + Vector3.forward * 2f); break;
                }
                Assert.That(Step(.34f, reason == "held"), Is.False);
                Assert.That(provider.Count, Is.Zero);
                Assert.That(teleport.Aiming || teleport.HasTarget, Is.False);
            }
            finally
            {
                if (panel) HandUiGuard.Rects.Remove(panel);
            }
        }

        [Test]
        public void SelectingWithTheNearGrabberNeverArms()
        {
            var manager = world.AddComponent<XRInteractionManager>();
            var near = new GameObject("Near grab");
            near.transform.SetParent(teleport.hand.transform, false);
            near.AddComponent<SphereCollider>().isTrigger = true;
            var grabber = near.AddComponent<HandGrabInteractor>();
            grabber.interactionManager = manager;
            teleport.hand.grabber = grabber;
            var item = new GameObject("Selected object");
            item.transform.SetParent(world.transform, false);
            item.AddComponent<BoxCollider>();
            var interactable = item.AddComponent<XRSimpleInteractable>();
            interactable.interactionManager = manager;
            manager.RegisterInteractor((IXRInteractor)grabber);
            manager.RegisterInteractable((IXRInteractable)interactable);
            manager.SelectEnter((IXRSelectInteractor)grabber, interactable);
            Assert.That(HandTeleport.Holding(teleport.hand), Is.True);
            Step(0f, HandTeleport.Holding(teleport.hand));
            Step(.32f, HandTeleport.Holding(teleport.hand));
            Assert.That(teleport.Aiming, Is.False);
            DropThumb();
            Assert.That(Step(.34f, HandTeleport.Holding(teleport.hand)), Is.False);
            Assert.That(provider.Count, Is.Zero);
        }

        [Test]
        public void SiblingAimWaitsForTheLeaseAndCanArmAfterTheOwnerDisables()
        {
            var other = AddHand(teleport.hand.transform.parent, out _);
            Step(0f);
            Step(.32f);
            Step(other, .34f);
            Step(other, .66f);
            Assert.That(teleport.Aiming, Is.True);
            Assert.That(other.Aiming || other.hand.GrabBlocked, Is.False);
            teleport.enabled = false;
            // Unity does not dispatch play-mode lifecycle callbacks for this component in EditMode.
            typeof(HandTeleport).GetMethod("OnDisable", BindingFlags.Instance | BindingFlags.NonPublic)
                .Invoke(teleport, null);
            Assert.That(teleport.Aiming || teleport.hand.GrabBlocked || teleport.HasTarget, Is.False);
            Step(other, .68f);
            Step(other, 1f);
            Assert.That(other.Aiming, Is.True);
        }

        [Test]
        public void ExternalPreemptionCancelsThePreviewAndReleasesTheGrabBlock()
        {
            Step(0f);
            Step(.32f);
            var cancelled = 0;
            teleport.AimEnded += (queued, _) => { if (!queued) cancelled++; };
            var lease = HandAimOwnership.For(teleport.hand.transform.parent);
            var external = new object();
            try
            {
                Assert.That(lease.Claim(external, null, owner => ReferenceEquals(owner, teleport)), Is.True);
                Assert.That(teleport.Aiming || teleport.HasTarget || teleport.hand.GrabBlocked, Is.False);
                Assert.That(cancelled, Is.EqualTo(1));
                DropThumb();
                Assert.That(Step(.34f), Is.False);
                Assert.That(provider.Count, Is.Zero);
            }
            finally { lease.Release(external); }
        }

        RectTransform RegisterPanel(Vector3 position)
        {
            var panel = new GameObject("Registered surface", typeof(RectTransform)).GetComponent<RectTransform>();
            panel.SetParent(world.transform, false);
            panel.position = position;
            panel.sizeDelta = new Vector2(2f, 2f);
            HandUiGuard.Rects.Add(panel);
            return panel;
        }

        bool Step(float now, bool held = false) => Step(teleport, now, held);

        static bool Step(HandTeleport adapter, float now, bool held = false)
        {
            adapter.hand.Tick(now);
            return adapter.Tick(now, held);
        }

        static Vector3[] Point()
        {
            var points = HandShapeTests.Hand(0f, 0f, 1f, 1f, 1f);
            for (var i = 0; i < HandCurls.PointsPerFinger; i++) points[i] += new Vector3(.06f, 0f, -.03f);
            return points;
        }

        void DropThumb() => tracking.points[ThumbHammer.ThumbTip] =
            tracking.points[ThumbHammer.IndexProximal] + Vector3.left * .01f;
    }
}
