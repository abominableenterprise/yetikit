using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace YetiKit.Interaction.Tests
{
    public sealed class PointPinchTeleportTests
    {
        sealed class Tracking : IHandTracking
        {
            public bool Pinched, OpenHand, Lost;

            public bool TryGetHand(bool right, Vector3[] into, out Pose wrist)
            {
                wrist = Pose.identity;
                for (var f = 0; f < FingerCurls.Fingers; f++)
                {
                    var offset = f * HandCurls.PointsPerFinger;
                    var p = f == 0 ? Vector3.zero : new Vector3((f - 2) * (right ? .02f : -.02f), 0f, .01f);
                    var direction = Quaternion.identity;
                    into[offset] = p;
                    for (var i = 1; i < HandCurls.PointsPerFinger; i++)
                    {
                        if (!OpenHand && f >= FingerCurls.Middle && i >= 2)
                            direction *= Quaternion.AngleAxis(HandCurls.FullBend[f][i - 2], Vector3.right);
                        p += direction * Vector3.forward * .03f;
                        into[offset + i] = p;
                    }
                }
                var tip = into[PinchStrength.IndexTip];
                var spread = Pinched ? .005f : .025f;
                into[PinchStrength.IndexTip] = tip + Vector3.right * spread;
                into[PinchStrength.ThumbTip] = tip - Vector3.right * spread;
                return !Lost;
            }
        }

        sealed class Provider : TeleportationProvider
        {
            public int Count;
            public override bool QueueTeleportRequest(TeleportRequest request) { Count++; return true; }
        }

        GameObject rig, floor;
        Transform head;
        Provider provider;
        PointPinchTeleport aim;
        Tracking tracking;
        string cancelled;

        [SetUp]
        public void Setup()
        {
            rig = new GameObject("Synthetic rig");
            rig.transform.position = new Vector3(150f, 0f, 0f);
            provider = rig.AddComponent<Provider>();
            head = new GameObject("Eyes").transform;
            head.SetParent(rig.transform, false);
            head.localPosition = new Vector3(0f, 1.6f, 0f);
            aim = Side(true, out tracking);
            aim.Cancelled += reason => cancelled = reason;
            floor = new GameObject("Synthetic pad");
            floor.transform.position = new Vector3(150f, -.1f, 0f);
            floor.AddComponent<BoxCollider>().size = new Vector3(40f, .2f, 40f);
            floor.AddComponent<TeleportationArea>().interactionLayers = 1;
            Physics.SyncTransforms();
        }

        [TearDown]
        public void Teardown()
        {
            Object.DestroyImmediate(rig);
            Object.DestroyImmediate(floor);
        }

        PointPinchTeleport Side(bool right, out Tracking source)
        {
            var space = new GameObject("Tracking space").transform;
            space.SetParent(rig.transform, false);
            space.localPosition = new Vector3(right ? .25f : -.25f, 1.4f, .3f);
            var root = new GameObject("Hand");
            root.transform.SetParent(space, false);
            var hand = root.AddComponent<PlayerHand>();
            hand.rightHand = right;
            hand.Tracking = source = new Tracking();
            var teleport = root.AddComponent<PointPinchTeleport>();
            teleport.hand = hand;
            teleport.head = head;
            teleport.provider = provider;
            teleport.teleportInteractionMask = 1;
            return teleport;
        }

        static bool Step(PointPinchTeleport teleport, float now, bool holding = false)
        {
            teleport.hand.Tick(now);
            return teleport.Tick(now, holding);
        }

        void Pinch()
        {
            Step(aim, 0f);
            Step(aim, .11f);
            Assert.That(aim.Aiming && aim.hand.GrabBlocked && aim.Aim.HasTarget, Is.True);
            tracking.Pinched = true;
            Assert.That(Step(aim, .12f), Is.False);
            Assert.That(aim.Pinching, Is.True);
        }

        [TestCase("no-target")]
        [TestCase("pose")]
        [TestCase("lost")]
        [TestCase("holding")]
        public void ActivePinchCancelsWithoutQueueing(string reason)
        {
            Pinch();
            tracking.Pinched = false;
            tracking.OpenHand = reason == "pose";
            tracking.Lost = reason == "lost";
            if (reason == "no-target") floor.SetActive(false);
            Assert.That(Step(aim, .13f, reason == "holding"), Is.False);
            Assert.That(cancelled, Is.EqualTo(reason));
            Assert.That(aim.Aiming || aim.Pinching || aim.Aim.HasTarget || aim.hand.GrabBlocked, Is.False);
            Assert.That(provider.Count, Is.Zero);
        }

        [Test]
        public void HandArrivingPinchedCannotConfirmOnItsFirstOpen()
        {
            tracking.Pinched = true;
            Step(aim, 0f);
            Step(aim, .11f);
            Assert.That(aim.Pinching, Is.False);
            tracking.Pinched = false;
            Assert.That(Step(aim, .12f), Is.False);
            tracking.Pinched = true;
            Step(aim, .13f);
            tracking.Pinched = false;
            Assert.That(Step(aim, .14f), Is.True);
            Assert.That(provider.Count, Is.EqualTo(1));
        }

        [Test]
        public void FirstPinchOwnsTheRigAndCooldownBlocksBothSidesUntilOpenAndRedwell()
        {
            var other = Side(false, out var left);
            Step(other, 0f);
            Step(other, .11f);
            Assert.That(other.Aiming, Is.True);
            Pinch();
            left.Pinched = true;
            Step(other, .12f);
            Assert.That(other.Aiming || other.hand.GrabBlocked, Is.False);
            tracking.Pinched = false;
            Assert.That(Step(aim, .13f), Is.True);
            Step(other, .5f);
            Step(aim, .5f);
            Assert.That(aim.Aiming || other.Aiming, Is.False);
            Step(other, .9f);
            Assert.That(other.Aiming, Is.False, "The cooldown has elapsed but this hand is still closed.");
            left.Pinched = false;
            Step(other, 1f);
            Assert.That(other.Aiming, Is.False, "Opening starts a new dwell.");
            Step(other, 1.11f);
            Assert.That(other.Aiming && other.Aim.HasTarget, Is.True);
            left.Pinched = true;
            Step(other, 1.12f);
            left.Pinched = false;
            Assert.That(Step(other, 1.13f), Is.True);
            Assert.That(provider.Count, Is.EqualTo(2));
        }

        [Test]
        public void HoldingAndReleaseQuietTimeDoNotAccumulateDwell()
        {
            Step(aim, 0f, true);
            Step(aim, .2f, true);
            Step(aim, .29f);
            Assert.That(aim.Aiming, Is.False);
            Step(aim, .31f);
            Assert.That(aim.Aiming, Is.False);
            Step(aim, .42f);
            Assert.That(aim.Aiming, Is.True);
        }
    }
}
