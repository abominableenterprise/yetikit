using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using YetiKit.Hands;

namespace YetiKit.Interaction.Tests
{
    public sealed class ReachGuardTests
    {
        static readonly Vector3 Tip = new Vector3(250f, 2f, 250f);
        GameObject world;
        RectTransform panel;

        [SetUp]
        public void SetUp()
        {
            world = new GameObject("Reach fixture");
            world.AddComponent<XRInteractionManager>();
        }

        [TearDown]
        public void TearDown()
        {
            if (panel) HandUiGuard.Rects.Remove(panel);
            Object.DestroyImmediate(world);
        }

        [Test]
        public void NearbyInteractablesGuardUnlessDisabledOrOwnedByTheHand()
        {
            var target = Target();
            target.AddComponent<TeleportationArea>();
            Physics.SyncTransforms();
            Assert.That(ReachGuard.Near(Tip, TeleportAim.UiReach), Is.False, "landing surfaces don't suppress reaching");
            Object.DestroyImmediate(target.GetComponent<TeleportationArea>());

            var grab = target.AddComponent<XRGrabInteractable>();
            Assert.That(ReachGuard.Near(Tip, TeleportAim.UiReach), Is.True);
            Assert.That(ReachGuard.Near(Tip, TeleportAim.UiReach, world.transform), Is.False);
            grab.enabled = false;
            Assert.That(ReachGuard.Near(Tip, TeleportAim.UiReach), Is.False);
        }

        [Test]
        public void RegisteredUiGuardsReachingNearItsEdge()
        {
            panel = new GameObject("UI", typeof(RectTransform)).GetComponent<RectTransform>();
            panel.SetParent(world.transform, false);
            panel.sizeDelta = new Vector2(2f, 2f);
            panel.position = Tip + Vector3.right + Vector3.forward * .14f;
            HandUiGuard.Rects.Add(panel);
            Assert.That(ReachGuard.Near(Tip, TeleportAim.UiReach), Is.True);
            HandUiGuard.Rects.Remove(panel);
            Assert.That(ReachGuard.Near(Tip, TeleportAim.UiReach), Is.False);
        }

        GameObject Target()
        {
            var target = new GameObject("Reachable target");
            target.transform.SetParent(world.transform, false);
            target.transform.position = Tip + Vector3.right * .12f;
            target.AddComponent<BoxCollider>().size = Vector3.one * .1f;
            return target;
        }
    }
}
