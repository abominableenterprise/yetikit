using System;
using System.Collections;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using YetiKit.Hands;
using YetiKit.Interaction;
using Object = UnityEngine.Object;

namespace YetiKit.Lab.Tests
{
    public sealed class GripOverrideTests
    {
        const string First = "block-a", Second = "block-b";
        const HandMode Controller = HandMode.Controller, Tracked = HandMode.TrackedHand;
        GameObject root;
        GripLabStation station;
        XRInteractionManager manager;
        MemoryStore store;

        [TearDown]
        public void CleanUp() { if (root) Object.DestroyImmediate(root); }

        [UnityTest]
        public IEnumerator OverridePrecedenceAndUndoAreIndependentForEachPropAndMode()
        {
            yield return new EnterPlayMode();
            Populate(new MemoryStore());
            var first = Slot(First);
            var prop = first.GetComponent<GrabbableProp>();
            var other = Slot(Second).GetComponent<GrabbableProp>();
            var adjust = station.Adjuster;
            Assert.That(prop.GripFor(true, Controller).radius, Is.EqualTo(0.04f)); // baked
            Assert.That(prop.GripFor(true, Tracked).radius, Is.EqualTo(0.03f)); // authored
            adjust.Begin(first, Tracked);
            var draft = Profile("tracked", 0.08f);
            adjust.Stage(draft);
            draft.spec.radius = 0.9f;
            Assert.That(prop.GripFor(true, Tracked).radius, Is.EqualTo(0.08f));
            Assert.That(prop.GripFor(true, Controller).radius, Is.EqualTo(0.04f));
            Assert.That(other.GripFor(true, Tracked).radius, Is.EqualTo(0.03f));
            Assert.That(store.Load(First, Tracked), Is.Null);
            adjust.Undo();
            Assert.That(prop.GripFor(true, Tracked), Is.EqualTo(prop.grip));
            adjust.Stage(Profile("tracked", 0.08f));
            adjust.Commit();
            Assert.That(prop.GripIdFor(Tracked), Is.EqualTo("tracked"));
            adjust.Stage(Profile("preview", 0.09f));
            adjust.End();
            Assert.That(prop.GripIdFor(Tracked), Is.EqualTo("tracked"));
            adjust.Begin(first, Controller);
            adjust.Stage(Profile("controller", 0.07f));
            adjust.Commit();
            adjust.Reset();
            Assert.That(prop.GripIdFor(Controller), Is.EqualTo("baked"));
            Assert.That(store.Load(First, Controller), Is.Null);
            adjust.Undo();
            Assert.That(prop.GripIdFor(Controller), Is.EqualTo("controller"));
            Assert.That(store.Load(First, Controller), Does.Contain("controller"));
            adjust.Undo();
            Assert.That(prop.GripIdFor(Controller), Is.EqualTo("baked"));
            Assert.That(prop.GripIdFor(Tracked), Is.EqualTo("tracked"));
            Assert.That(store.Load(First, Tracked), Does.Contain("tracked"));
            CleanUp();
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator ReloadsVersionOneAndDoesNotRewriteUnsupportedOrOtherKeys()
        {
            yield return new EnterPlayMode();
            var memory = new MemoryStore();
            Populate(memory);
            station.Adjuster.Begin(Slot(First), Tracked);
            var profile = Profile("saved", 0.08f);
            profile.spec.shift = Vector3.right * 0.02f;
            station.Adjuster.Stage(profile);
            station.Adjuster.Commit();
            var body = memory.Load(First, Tracked);
            Assert.That(body, Is.Not.Null, "Commit writes a versioned document.");
            Assert.That(body, Does.Contain("\"v\":1"));
            const string future = "{\"v\":2,\"opaque\":true}";
            const string bad = "{\"v\":1,\"profile\":{\"id\":\"missing-spec\"}}";
            memory.Save(First, Controller, future);
            memory.Save(Second, Tracked, bad);
            memory.Save("unlisted", Tracked, "opaque");
            memory.Save(First, Tracked, "{\"extra\":[1,2]," + body.Substring(1));
            CleanUp();
            Populate(memory);
            var first = Slot(First).GetComponent<GrabbableProp>();
            Assert.That(first.GripFor(true, Tracked), Is.EqualTo(profile.spec));
            Assert.That(first.GripIdFor(Tracked), Is.EqualTo("saved"));
            Assert.That(first.GripIdFor(Controller), Is.EqualTo("baked"));
            Assert.That(Slot(Second).GetComponent<GrabbableProp>().GripIdFor(Tracked), Is.Empty);
            station.Adjuster.Begin(Slot(First), Controller);
            Assert.Throws<InvalidOperationException>(() => station.Adjuster.Reset());
            station.Adjuster.Begin(Slot(Second), Tracked);
            station.Adjuster.Stage(Profile("replacement", 0.07f));
            Assert.Throws<InvalidOperationException>(() => station.Adjuster.Commit());
            Assert.That(Slot(Second).GetComponent<GrabbableProp>().GripIdFor(Tracked), Is.Empty);
            station.Adjuster.Begin(Slot(First), Tracked);
            station.Adjuster.Reset();
            Assert.That(first.GripIdFor(Tracked), Is.Empty);
            Assert.That(memory.Load(First, Tracked), Is.Null);
            Assert.That(memory.Load(First, Controller), Is.EqualTo(future));
            Assert.That(memory.Load(Second, Tracked), Is.EqualTo(bad));
            Assert.That(memory.Load("unlisted", Tracked), Is.EqualTo("opaque"));
            CleanUp();
            yield return new ExitPlayMode();
        }

        [UnityTest]
        public IEnumerator ActiveHoldRefitsInPlaceOnPreviewUndoAndReset()
        {
            yield return new EnterPlayMode();
            VerifyHeldRefit();
            yield return new ExitPlayMode();
        }

        void VerifyHeldRefit()
        {
            Populate(new MemoryStore());
            var slot = Slot(First);
            var grab = slot.GetComponent<PropGrabInteractable>();
            Assert.That(grab, Is.Not.Null);
            var interactor = Input("Synthetic hand");
            var hand = interactor.gameObject;
            var visual = new GripVisual(hand.transform);
            var playerHand = Child("Synthetic hand root").AddComponent<PlayerHand>();
            Assert.That(playerHand, Is.Not.Null, "The synthetic hand root must exist.");
            playerHand.controller = hand.transform;
            playerHand.Visual = visual;
            grab.SetGripMode(Tracked);
            var selections = 0;
            grab.selectEntered.AddListener(_ => selections++);
            manager.SelectEnter((IXRSelectInteractor)interactor, grab);
            Assert.That(grab.isSelected, Is.True);
            var original = grab.attachTransform.localPosition;
            var adjust = station.Adjuster;
            adjust.Begin(slot, Controller);
            var before = visual.Fits;
            adjust.Stage(Profile("not held", 0.09f));
            Assert.That(visual.Fits, Is.EqualTo(before));
            adjust.End();
            adjust.Begin(slot, Tracked);
            adjust.Stage(Profile("preview", 0.09f));
            Assert.That(visual.Last.radius, Is.EqualTo(0.09f));
            Assert.That(Vector3.Distance(grab.attachTransform.localPosition, original), Is.GreaterThan(0.01f));
            adjust.Undo();
            Assert.That(Vector3.Distance(grab.attachTransform.localPosition, original), Is.LessThan(0.0001f));
            adjust.Stage(Profile("saved", 0.1f));
            adjust.Commit();
            adjust.Reset();
            Assert.That(Vector3.Distance(grab.attachTransform.localPosition, original), Is.LessThan(0.0001f));
            Assert.That(grab.isSelected, Is.True);
            Assert.That(grab.ReleaseSequence, Is.Zero);
            Assert.That(selections, Is.EqualTo(1));
            CleanUp();
        }

        [UnityTest]
        public IEnumerator BorrowedInputRestoresOnStationDisableAndSaveException()
        {
            yield return new EnterPlayMode();
            VerifyInputRestoration();
            yield return new ExitPlayMode();
        }

        void VerifyInputRestoration()
        {
            Populate(new MemoryStore());
            var slot = Slot(First);
            var active = Input("Synthetic input");
            var inactive = Input("Initially disabled input");
            Assert.That(active, Is.Not.Null);
            Assert.That(inactive, Is.Not.Null);
            inactive.enabled = false;
            var adjust = station.Adjuster;
            adjust.Begin(slot, Controller, active, inactive, active);
            Assert.That(active.enabled, Is.False);
            adjust.Stage(Profile("temporary", 0.08f));
            station.enabled = false;
            Assert.That(active.enabled, Is.True);
            Assert.That(inactive.enabled, Is.False);
            Assert.That(slot.GetComponent<GrabbableProp>().GripIdFor(Controller), Is.EqualTo("baked"));
            station.enabled = true;
            adjust.Begin(slot, Controller, active, inactive);
            adjust.Stage(Profile("temporary", 0.08f));
            store.FailSave = true;
            Assert.Throws<InvalidOperationException>(() => adjust.Commit());
            Assert.That(active.enabled, Is.True);
            Assert.That(inactive.enabled, Is.False);
            Assert.That(slot.GetComponent<GrabbableProp>().GripIdFor(Controller), Is.EqualTo("baked"));
            Assert.That(store.Load(First, Controller), Is.Null);
            adjust.Begin(slot, Controller, active);
            slot.enabled = false;
            Assert.That(active.enabled, Is.True);
            slot.enabled = true;
            adjust.Begin(slot, Controller, active);
            station.Back();
            Assert.That(active.enabled, Is.True);
            CleanUp();
        }

        [Test]
        public void LocalStoreSeparatesCatalogScopesPropIdsAndModes()
        {
            var scope = Guid.NewGuid().ToString("N");
            var local = new PlayerPrefsGripOverrideStore(scope);
            var other = new PlayerPrefsGripOverrideStore(scope + ".controller");
            try
            {
                local.Save(First, Controller, "first controller");
                local.Save(First, Tracked, "first tracked");
                local.Save(Second, Controller, "second controller");
                other.Save(First, Controller, "other catalog");
                var reloaded = new PlayerPrefsGripOverrideStore(scope);
                reloaded.Save(First, Controller, null);
                Assert.That(local.Load(First, Controller), Is.Null);
                Assert.That(reloaded.Load(First, Tracked), Is.EqualTo("first tracked"));
                Assert.That(reloaded.Load(Second, Controller), Is.EqualTo("second controller"));
                Assert.That(other.Load(First, Controller), Is.EqualTo("other catalog"));
            }
            finally
            {
                local.Save(First, Controller, null);
                local.Save(First, Tracked, null);
                local.Save(Second, Controller, null);
                other.Save(First, Controller, null);
            }
        }

        void Populate(MemoryStore memory)
        {
            store = memory;
            root = new GameObject("Synthetic station");
            manager = root.AddComponent<XRInteractionManager>();
            station = root.AddComponent<GripLabStation>();
            station.Populate(new Catalog { Entries = new[] {
                new InteractableEntry(First, "Block A", MakeProp), new InteractableEntry(Second, "Block B", MakeProp)
            }}, store);
        }

        GripLabSlot Slot(string id) => Array.Find(root.GetComponentsInChildren<GripLabSlot>(), slot => slot.Id == id);

        XRDirectInteractor Input(string label)
        {
            var go = Child(label);
            go.AddComponent<BoxCollider>().isTrigger = true;
            return go.AddComponent<XRDirectInteractor>();
        }

        GameObject Child(string label)
        {
            var go = new GameObject(label);
            go.transform.SetParent(root.transform, false);
            return go;
        }

        static GameObject MakeProp()
        {
            var item = new GameObject("Synthetic prop");
            item.AddComponent<BoxCollider>().size = Vector3.one * 0.12f;
            item.AddComponent<GrabbableProp>().gripProfiles.controller = Profile("baked", 0.04f);
            return item;
        }

        static GripProfile Profile(string id, float radius) =>
            new GripProfile(id, new GripSpec(GripKind.Cylinder, Vector3.up, Vector3.forward, Vector3.zero, radius));

        sealed class Catalog : IInteractableCatalog
        {
            public IReadOnlyList<InteractableEntry> Entries { get; set; }
        }

        sealed class GripVisual : IHandVisual, IHeldVisual
        {
            readonly Transform frame;
            public GripVisual(Transform frame) => this.frame = frame;
            public int Fits;
            public GripSpec Last;
            public event Action GripChanged { add { } remove { } }
            public bool TryGetGripFrame(out Transform model, out Vector3 knuckles)
            {
                model = frame;
                knuckles = Vector3.zero;
                return true;
            }
            public Pose FitGrip(PropGrabInteractable prop, GripSpec grip, Pose authoredPose) => authoredPose;
            public void Hold(PropGrabInteractable prop, GripSpec grip, Pose pose) { Last = grip; Fits++; }
            public void Release(PropGrabInteractable prop) { }
            public void OnPresence(bool present) { }
            public void OnPose(Pose wrist, JointCurls curls, Pose[] joints) { }
            public void OnControllerInput(float grip, float trigger) { }
        }

        sealed class MemoryStore : IGripOverrideStore
        {
            readonly Dictionary<(string, HandMode), string> documents = new Dictionary<(string, HandMode), string>();
            public bool FailSave;
            public string Load(string id, HandMode mode) => documents.TryGetValue((id, mode), out var body) ? body : null;
            public void Save(string id, HandMode mode, string body)
            {
                if (FailSave) throw new InvalidOperationException("Synthetic save failure.");
                if (body == null) documents.Remove((id, mode));
                else documents[(id, mode)] = body;
            }
        }
    }
}
