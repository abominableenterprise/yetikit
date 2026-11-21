using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace YetiKit.Interaction.Tests
{
    public sealed class TeleportGroundTests
    {
        static readonly Vector3 Offset = new Vector3(200f, 0f, 200f);
        static Vector3 Origin => Offset + Vector3.up;
        GameObject world;
        TeleportationArea floor;
        TeleportAim aim;
        Transform rig;

        [SetUp]
        public void SetUp()
        {
            world = new GameObject("Ground fixture");
            world.AddComponent<XRInteractionManager>();
            floor = Box("Floor", Vector3.down * .1f, new Vector3(20f, .2f, 20f)).AddComponent<TeleportationArea>();
            floor.interactionLayers = 1;
            rig = new GameObject("Rig").transform;
            rig.SetParent(world.transform, false);
            aim = new TeleportAim { LandingAllowed = hit => TeleportGround.Matches(hit, rig) };
        }

        [TearDown]
        public void TearDown() => Object.DestroyImmediate(world);

        [TestCase(false)]
        [TestCase(true)]
        public void FirstSurfaceAboveTheArcLandingBlocksEvenIfItsAnotherTeleportArea(bool teleport)
        {
            Cast(rig);
            Assert.That(aim.HasTarget, Is.True);
            var landing = aim.Target.destinationPosition;
            var overhead = Box("Overhead obstacle", landing - Offset + Vector3.up, Vector3.one * .2f);
            if (teleport) overhead.AddComponent<TeleportationArea>().interactionLayers = floor.interactionLayers;
            Physics.SyncTransforms();

            Assert.That(aim.Revalidate(), Is.False, "confirm must check the current probe without moving the target");
            Cast(rig);
            Assert.That(aim.HasTarget, Is.False);
            Assert.That(aim.ArcHit.Value.point, Is.EqualTo(landing), "only the downward probe hits the obstacle");
        }

        [Test]
        public void ArcAndDownwardProbeBothSkipTheRig()
        {
            Cast(rig);
            Assert.That(aim.HasTarget, Is.True);
            var landing = aim.Target.destinationPosition;
            var overhead = Box("Rig overhead", landing - Offset + Vector3.up, Vector3.one * .2f);
            overhead.transform.SetParent(rig, true);
            var inArc = Box("Rig in arc", new Vector3(0f, .95f, 1f), Vector3.one * .2f);
            inArc.transform.SetParent(rig, true);

            Cast(null);
            Assert.That(aim.HasTarget, Is.False);
            Assert.That(aim.ArcHit.Value.collider.gameObject, Is.SameAs(inArc));
            Cast(rig);
            Assert.That(aim.HasTarget, Is.True);
            Assert.That(aim.ArcHit.Value.point, Is.EqualTo(landing));
            Assert.That(TeleportGround.Matches(aim.ArcHit.Value, null), Is.False);
        }

        [Test]
        public void ProbeMayHitADifferentColliderOnTheSameArea()
        {
            Cast(rig);
            Assert.That(aim.HasTarget, Is.True);
            var landing = aim.Target.destinationPosition;
            var overhead = Box("Second area collider", landing - Offset + Vector3.up, Vector3.one * .2f);
            overhead.transform.SetParent(floor.transform, true);

            Cast(rig);
            Assert.That(aim.HasTarget, Is.True);
            Assert.That(aim.Target.destinationPosition, Is.EqualTo(landing));
        }

        void Cast(Transform ignore)
        {
            Physics.SyncTransforms();
            aim.CastWithMask(Origin, Vector3.forward, null, floor.interactionLayers, ignoreRig: ignore);
        }

        GameObject Box(string name, Vector3 at, Vector3 size)
        {
            var go = new GameObject(name);
            go.transform.SetParent(world.transform, false);
            go.transform.position = Offset + at;
            go.AddComponent<BoxCollider>().size = size;
            return go;
        }
    }
}
