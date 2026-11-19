using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using YetiKit.Hands;
using YetiKit.Interaction;
using YetiKit.Playtest;

namespace YetiKit.Lab.Tests
{
    public sealed class GripLabTests
    {
        sealed class Catalog : IInteractableCatalog
        {
            public System.Collections.Generic.IReadOnlyList<InteractableEntry> Entries { get; set; }
        }

        [UnityTest]
        public IEnumerator CatalogPlacesEachPropByItsColliderBoundsAndStartsItFixed()
        {
            yield return new EnterPlayMode();
            var root = new GameObject("Fixture");
            try
            {
                root.AddComponent<XRInteractionManager>();
                var station = root.AddComponent<GripLabStation>();
                root.transform.position = new Vector3(2, 0.8f, 3);
                var source = MakeProp("template", new Vector3(1.6f, 0.4f, 0.6f));
                source.transform.SetParent(root.transform);
                var calls = 0;
                station.Populate(new Catalog { Entries = new[] {
                    new InteractableEntry("wide", "Wide", source.gameObject, "blocks"),
                    new InteractableEntry("tall", "Tall", () => { calls++; return MakeProp("tall", new Vector3(1.6f, 0.7f, 0.4f)).gameObject; })
                }});
                Physics.SyncTransforms();
                var slots = root.GetComponentsInChildren<GripLabSlot>();
                Assert.That(slots, Has.Length.EqualTo(2));
                Assert.That(calls, Is.EqualTo(1));
                Assert.That(root.GetComponentsInChildren<GrabbableProp>(), Has.Length.EqualTo(3));
                var a = slots[0].GetComponent<BoxCollider>().bounds;
                var b = slots[1].GetComponent<BoxCollider>().bounds;
                Assert.That(a.min.y, Is.EqualTo(root.transform.position.y + 0.002f).Within(0.001f));
                Assert.That(b.min.y, Is.EqualTo(a.min.y).Within(0.001f));
                Assert.That(b.min.z, Is.GreaterThan(a.max.z));
                foreach (var slot in slots)
                {
                    Assert.That(slot.IsFixedInSlot, Is.True);
                    Assert.That(slot.GetComponent<Rigidbody>().isKinematic, Is.True);
                }
            }
            finally { Object.DestroyImmediate(root); }
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator GrabAndTouchReleasePropsThenDropTimerAndResetReturnThem()
        {
            yield return new EnterPlayMode();
            var root = new GameObject("Fixture");
            try
            {
                var manager = root.AddComponent<XRInteractionManager>();
                var station = root.AddComponent<GripLabStation>();
                station.Head = root.transform;
                var log = new FlightLog(() => 0);
                using var registration = log.Register(station.FlightEvents);
                station.Populate(new Catalog { Entries = new[] {
                    new InteractableEntry("block", "Block", () => MakeProp("block", Vector3.one * 0.15f).gameObject)
                }});
                var slot = root.GetComponentInChildren<GripLabSlot>();
                var grab = slot.GetComponent<PropGrabInteractable>();
                var body = slot.GetComponent<Rigidbody>();
                var home = slot.transform.position;
                var handObject = new GameObject("Hand");
                handObject.transform.SetParent(root.transform);
                var hand = handObject.AddComponent<XRDirectInteractor>();
                var handCollider = handObject.AddComponent<BoxCollider>();
                handCollider.isTrigger = true;
                var handRoot = new GameObject("Hand root");
                handRoot.transform.SetParent(root.transform);
                handRoot.AddComponent<PlayerHand>().controller = handObject.transform;
                handObject.transform.position = home;
                Physics.SyncTransforms();
                slot.SendMessage("FixedUpdate");
                Assert.That(slot.IsFixedInSlot, Is.True, "A hover volume is not touch.");

                manager.SelectEnter((IXRSelectInteractor)hand, grab);
                Assert.That(slot.IsFixedInSlot, Is.False);
                Assert.That(log.Count("griplab"), Is.EqualTo(1));
                Assert.That(log.Buffer.ToString(), Does.Contain("\"prop\":\"block\""));
                station.Tick(30);
                Assert.That(grab.isSelected, Is.True);
                manager.SelectExit((IXRSelectInteractor)hand, grab);
                Assert.That(body.isKinematic, Is.False, "Selection must capture a dynamic body.");
                station.Tick(2);
                Assert.That(slot.IsFixedInSlot, Is.False);
                station.Tick(1);
                Assert.That(slot.IsFixedInSlot, Is.True);
                Assert.That(Vector3.Distance(body.position, home), Is.LessThan(0.0001f));

                handCollider.isTrigger = false;
                Physics.SyncTransforms();
                slot.SendMessage("FixedUpdate");
                Assert.That(slot.IsFixedInSlot, Is.False, "Physical hand contact releases a fixed prop.");
                body.position = home + Vector3.left;
                body.linearVelocity = Vector3.one;
                manager.SelectEnter((IXRSelectInteractor)hand, grab);
                station.ResetAll();
                Assert.That(grab.isSelected, Is.False);
                Assert.That(slot.IsFixedInSlot, Is.True);
                Assert.That(Vector3.Distance(body.position, home), Is.LessThan(0.0001f));
                Assert.That(body.linearVelocity, Is.EqualTo(Vector3.zero));
                manager.SelectEnter((IXRSelectInteractor)hand, grab);
                Assert.That(grab.isSelected, Is.True);
                VerifyBack(station, slot, grab);
            }
            finally { Object.DestroyImmediate(root); }
            yield return new ExitPlayMode();
        }

        static void VerifyBack(GripLabStation station, GripLabSlot slot, PropGrabInteractable grab)
        {
            var back = 0;
            station.BackRequested.AddListener(() =>
            {
                Assert.That(grab.isSelected, Is.False, "Back settles the grab before navigation.");
                back++;
                station.gameObject.SetActive(false);
            });
            station.Back();
            Assert.That(back, Is.EqualTo(1));
            Assert.That(slot.transform.parent, Is.EqualTo(station.transform));
            Assert.That(slot.gameObject.activeInHierarchy, Is.False);
            station.gameObject.SetActive(true);
            Assert.That(slot.IsFixedInSlot, Is.True);
        }

        static GrabbableProp MakeProp(string label, Vector3 size)
        {
            var item = new GameObject(label);
            var collider = item.AddComponent<BoxCollider>();
            collider.center = new Vector3(0.15f, 0.1f, 0.2f);
            collider.size = size;
            return item.AddComponent<GrabbableProp>();
        }
    }
}
