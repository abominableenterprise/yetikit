using NUnit.Framework;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;

namespace YetiKit.Hands.Tests
{
    public sealed class TeleportAimTests
    {
        const string Layer = "Default"; // XRI's built-in layer; no project-specific settings needed.
        static readonly Vector3 Offset = new Vector3(100f, 0f, 100f);
        static Vector3 Origin => Offset + Vector3.up;

        GameObject root, reticle;
        RectTransform panel;
        BoxCollider box;
        TeleportationArea area;
        TeleportAim aim;
        LineRenderer line;

        [SetUp]
        public void SetUp()
        {
            aim = new TeleportAim();
            root = new GameObject("Aim fixture");
            root.transform.position = Offset;
            line = root.AddComponent<LineRenderer>();
            line.useWorldSpace = false;
            reticle = new GameObject("Reticle");
            reticle.transform.SetParent(root.transform, false);
            reticle.SetActive(false);

            var floor = new GameObject("Landing area");
            floor.transform.SetParent(root.transform, false);
            box = floor.AddComponent<BoxCollider>();
            box.size = new Vector3(20f, 0.2f, 20f);
            box.center = Vector3.down * 0.1f;
            area = floor.AddComponent<TeleportationArea>();
            area.interactionLayers = InteractionLayerMask.GetMask(Layer);
            area.matchOrientation = MatchOrientation.WorldSpaceUp;
            Physics.SyncTransforms();
        }

        [TearDown]
        public void TearDown()
        {
            if (panel) HandUiGuard.Rects.Remove(panel);
            Object.DestroyImmediate(root);
            if (reticle) Object.DestroyImmediate(reticle);
        }

        [TestCase(false, 2f)]
        [TestCase(true, 1.5f)]
        public void TheArcStopsAtTheFirstBlocker(bool customBlocker, float stop)
        {
            RegisterPanel(Origin + Vector3.forward * 2f);
            if (customBlocker) aim.Blocker = BlockAtPlane;
            Cast();
            Preview();
            Assert.That(aim.HasTarget, Is.False);
            Assert.That(reticle.activeSelf, Is.False);
            Assert.That(line.enabled, Is.True);
            Assert.That(ArcEnd.z - Offset.z, Is.EqualTo(stop).Within(1e-4f));
        }

        [Test]
        public void UiBeyondTheFirstPhysicsHitDoesNotBlockLanding()
        {
            RegisterPanel(Origin + Vector3.forward * 5f);
            Cast();
            Assert.That(aim.HasTarget, Is.True);
            Assert.That(aim.Revalidate(), Is.True);
        }

        [Test]
        public void LandingRequiresTheNamedXriLayer()
        {
            aim.Cast(Origin, Vector3.forward, null, "Missing Fixture Layer");
            Assert.That(aim.HasTarget, Is.False);
            Cast();
            Assert.That(aim.HasTarget, Is.True);
        }

        [Test]
        public void AnAnchorIsNotAFreeformLandingSurface()
        {
            var floor = area.gameObject;
            Object.DestroyImmediate(area);
            var anchor = floor.AddComponent<TeleportationAnchor>();
            anchor.interactionLayers = InteractionLayerMask.GetMask(Layer);
            Cast();
            Preview();
            Assert.That(aim.HasTarget, Is.False);
            Assert.That(reticle.activeSelf, Is.False);
        }

        [Test]
        public void TheReticleStaysAtTheLandingWhenTheHandMoves()
        {
            Cast();
            Assert.That(aim.HasTarget, Is.True);
            root.transform.rotation = Quaternion.Euler(25f, 60f, 0f);
            Preview();
            var target = aim.Target.destinationPosition;
            Assert.That(line.useWorldSpace, Is.True);
            Assert.That(Vector3.Distance(ArcEnd, target), Is.LessThan(1e-4f));
            Assert.That(reticle.activeSelf, Is.True);
            Assert.That(reticle.transform.parent, Is.Null);
            root.transform.SetPositionAndRotation(Offset + Vector3.right, Quaternion.identity);
            Assert.That(Vector3.Distance(reticle.transform.position, target), Is.LessThan(1e-4f));
            Assert.That(Vector3.Dot(reticle.transform.up, Vector3.up), Is.GreaterThan(0.999f));
            Assert.That(Vector3.Dot(reticle.transform.forward, Quaternion.Euler(0f, 60f, 0f) * Vector3.forward),
                Is.GreaterThan(0.999f));
            aim.Show(false, line, null, null, reticle, root.transform);
            Assert.That(line.enabled || reticle.activeSelf, Is.False);
            aim.DestroyReticle(reticle);
            Assert.That(!reticle, Is.True);
        }

        [Test]
        public void CleanupDestroysOnlyTheReticleThatWasDetached()
        {
            Cast();
            Preview();
            Assert.That(reticle.transform.parent, Is.Null);
            var replacement = new GameObject("Replacement reticle");
            replacement.transform.SetParent(root.transform, false);
            aim.DestroyReticle(replacement);
            Assert.That(!reticle, Is.True);
            Assert.That(replacement, Is.Not.Null);
            Assert.That(replacement.transform.parent, Is.EqualTo(root.transform));
        }

        [TestCase("intersecting UI")]
        [TestCase("nearby UI")]
        [TestCase("custom blocker")]
        [TestCase("landing policy")]
        [TestCase("area disabled")]
        [TestCase("collider disabled")]
        [TestCase("area destroyed")]
        [TestCase("collider destroyed")]
        [TestCase("layer changed")]
        public void RevalidationUsesCurrentPoliciesWithoutSteeringTheFrozenArc(string change)
        {
            Cast();
            Assert.That(aim.Revalidate(), Is.True);
            Preview();
            var target = aim.Target.destinationPosition;
            var frozen = new Vector3[line.positionCount];
            line.GetPositions(frozen);

            switch (change)
            {
                case "intersecting UI": RegisterPanel(Origin + Vector3.forward * 2f); break;
                case "nearby UI": RegisterPanel(target + Vector3.forward * 0.1f); break;
                case "custom blocker": aim.Blocker = BlockAtPlane; break;
                case "landing policy": aim.LandingAllowed = hit => hit.point != target; break;
                case "area disabled": area.enabled = false; break;
                case "collider disabled": box.enabled = false; break;
                case "area destroyed": Object.DestroyImmediate(area); break;
                case "collider destroyed": Object.DestroyImmediate(box); break;
                case "layer changed": area.interactionLayers = 0; break;
            }

            Assert.That(aim.Revalidate(), Is.False);
            Assert.That(aim.HasTarget, Is.False);
            Assert.That(aim.Target.destinationPosition, Is.EqualTo(target));
            Preview();
            Assert.That(reticle.activeSelf, Is.False);
            Assert.That(line.positionCount, Is.EqualTo(frozen.Length));
            var after = new Vector3[line.positionCount];
            line.GetPositions(after);
            Assert.That(after, Is.EqualTo(frozen));
        }

        void Cast() => aim.Cast(Origin, Vector3.forward, null, Layer);
        void Preview() => aim.Show(true, line, null, null, reticle, root.transform);
        Vector3 ArcEnd => line.GetPosition(line.positionCount - 1);

        void RegisterPanel(Vector3 position)
        {
            panel = new GameObject("Collider-free panel", typeof(RectTransform)).GetComponent<RectTransform>();
            panel.SetParent(root.transform, false);
            panel.sizeDelta = new Vector2(2f, 2f);
            panel.position = position;
            HandUiGuard.Rects.Add(panel);
        }

        static bool BlockAtPlane(Vector3 from, Vector3 to, out Vector3 hit)
        {
            var z = Offset.z + 1.5f;
            hit = default;
            if (from.z > z || to.z < z || to.z <= from.z) return false;
            hit = Vector3.Lerp(from, to, (z - from.z) / (to.z - from.z));
            return true;
        }
    }
}
