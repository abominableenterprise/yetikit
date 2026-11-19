using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Interaction.Tests
{
    public class HeldCollisionIgnoresTests
    {
        [Test]
        public void ColliderReactivationDuringHoldKeepsTheIgnoreUntilRelease()
        {
            var first = new GameObject("First held body");
            var second = new GameObject("Second held body");
            first.AddComponent<Rigidbody>().isKinematic = true;
            second.AddComponent<Rigidbody>().isKinematic = true;
            var a = first.AddComponent<BoxCollider>();
            var b = second.AddComponent<BoxCollider>();
            var held = true;
            var left = new HeldPairs(new Collider[] { a }, () => held, () => held);
            var right = new HeldPairs(new Collider[] { b }, () => held, () => held);
            try
            {
                left.Enable();
                right.Grab();
                Assert.That(Physics.GetIgnoreCollision(a, b), Is.True, "the lease initially ignores the pair");

                a.enabled = false;
                right.Tick();
                a.enabled = true;
                Physics.SyncTransforms();
                TestContext.WriteLine($"Ignored after toggling, before Tick: {Physics.GetIgnoreCollision(a, b)}");

                right.Tick();
                Assert.That(Physics.GetIgnoreCollision(a, b), Is.True, "the reactivated pair is still held");

                held = false;
                second.transform.position = Vector3.right * 5f;
                Physics.SyncTransforms();
                right.Tick();
                Assert.That(Physics.GetIgnoreCollision(a, b), Is.False, "the ended lease restores collision");
            }
            finally
            {
                right.Disable();
                left.Disable();
                Object.DestroyImmediate(second);
                Object.DestroyImmediate(first);
            }
        }
    }
}
