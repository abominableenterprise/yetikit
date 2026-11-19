using System;
using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEditor.PackageManager;
using UnityEngine;
using YetiKit.Hands;

namespace YetiKit.Lab.Tests
{
    public sealed class ExperimentTests
    {
        [TestCase(null)]
        [TestCase("retired")]
        public void StartupFallsBackWithoutWriteback(string saved)
        {
            var store = new Store();
            store.Save("sample", saved);
            using var switcher = new ExperimentSwitcher("sample", Registry(), new Hand(false), new Hand(true), store);
            Assert.That(switcher.CurrentId, Is.EqualTo("first"));
            Assert.That(store.Load("sample"), Is.EqualTo(saved));
            Assert.That(store.Writes, Is.EqualTo(1));
            Assert.That(switcher.Select("unknown"), Is.False);
            Assert.That(store.Writes, Is.EqualTo(1));
        }

        [Test]
        public void SwitchRestoresInputAndDisposesEachInstanceExactlyOnce()
        {
            var events = new List<string>();
            var registry = Registry(id => new Experiment(id, events));
            var switcher = new ExperimentSwitcher("sample", registry, new Hand(false), new Hand(true), new Store(), () =>
            {
                events.Add("borrow");
                return new Lease(() => events.Add("restore"));
            });
            switcher.Tick(1);
            Assert.That(switcher.Select("second"), Is.True);
            switcher.Dispose();
            switcher.Dispose();
            CollectionAssert.AreEqual(new[] {
                "borrow", "init:first:False", "enable:first", "init:first:True", "enable:first", "tick:first", "tick:first",
                "disable:first", "dispose:first", "disable:first", "dispose:first", "restore",
                "borrow", "init:second:False", "enable:second", "init:second:True", "enable:second",
                "disable:second", "dispose:second", "disable:second", "dispose:second", "restore"
            }, events);
        }

        [TestCase(false)]
        [TestCase(true)]
        public void DisposingFromEnableAbortsSelectionWithoutLeakingHands(bool disposeFromRight)
        {
            var events = new List<string>();
            var store = new Store();
            store.Save("sample", "first");
            ExperimentSwitcher switcher = null;
            var registry = Registry(id => new Experiment(id, events, onEnable: right =>
            {
                if (id != "second" || right != disposeFromRight) return;
                switcher.Dispose();
                switcher.Tick(1);
                events.Add("enable finished");
            }));
            using (switcher = new ExperimentSwitcher("sample", registry, new Hand(false), new Hand(true),
                       store, () => new Lease(() => events.Add("restore"))))
            {
                events.Clear();
                var selected = switcher.Select("second");
                switcher.Tick(2);
                switcher.Dispose();

                var expected = new List<string> {
                    "disable:first", "dispose:first", "disable:first", "dispose:first", "restore",
                    "init:second:False", "enable:second"
                };
                if (disposeFromRight) expected.AddRange(new[] { "init:second:True", "enable:second" });
                expected.AddRange(new[] { "enable finished", "disable:second", "dispose:second" });
                if (disposeFromRight) expected.AddRange(new[] { "disable:second", "dispose:second" });
                expected.Add("restore");
                CollectionAssert.AreEqual(expected, events);
                Assert.That(selected, Is.False);
                Assert.That(switcher.CurrentId, Is.Null);
                Assert.That(store.Load("sample"), Is.EqualTo("first"));
                Assert.That(store.Writes, Is.EqualTo(1));
            }
        }

        [Test]
        public void FailedEnableReleasesBothInstancesAndRestoresInput()
        {
            var events = new List<string>();
            var registry = Registry(id => new Experiment(id, events, failRight: true));
            Assert.Throws<InvalidOperationException>(() => new ExperimentSwitcher("sample", registry,
                new Hand(false), new Hand(true), new Store(), () => new Lease(() => events.Add("restore"))));
            CollectionAssert.AreEqual(new[] {
                "init:first:False", "enable:first", "init:first:True", "enable:first",
                "disable:first", "dispose:first", "disable:first", "dispose:first", "restore"
            }, events);
        }

        [Test]
        public void DefaultStorePersistsSelectionPerLab()
        {
            var prefix = Guid.NewGuid().ToString("N");
            try
            {
                var registry = Registry();
                using (var a = new ExperimentSwitcher(prefix + "-a", registry, new Hand(false), new Hand(true)))
                    a.Select("second");
                using var reopened = new ExperimentSwitcher(prefix + "-a", registry, new Hand(false), new Hand(true));
                using var other = new ExperimentSwitcher(prefix + "-b", registry, new Hand(false), new Hand(true));
                Assert.That(reopened.CurrentId, Is.EqualTo("second"));
                Assert.That(other.CurrentId, Is.EqualTo("first"));
            }
            finally
            {
                PlayerPrefs.DeleteKey("YetiKit.Lab.Selection." + prefix + "-a");
                PlayerPrefs.DeleteKey("YetiKit.Lab.Selection." + prefix + "-b");
                PlayerPrefs.Save();
            }
        }

        [Test]
        public void RegistrationTokenRemovesOnlyItsEntry()
        {
            var registry = new ExperimentRegistry();
            var registration = registry.Add("first", () => new Experiment("first"));
            using var second = registry.Add("second", () => new Experiment("second"));
            Assert.That(registry.Resolve(null), Is.EqualTo("first"));
            registration.Dispose();
            using var replacement = registry.Add("first", () => new Experiment("first"));
            registration.Dispose();
            Assert.That(registry.Resolve("first"), Is.EqualTo("first"));
            Assert.That(registry.Resolve(null), Is.EqualTo("second"));
        }

        [Test]
        public void LaunchTargetIsInjectedAndDoesNotChangeSavedSelection()
        {
            string loaded = null;
            DevBoot.Launch(() => ("SampleScene", "second"), scene => loaded = scene);
            try
            {
                using var switcher = new ExperimentSwitcher("sample", Registry(), new Hand(false), new Hand(true),
                    new Store(), initialId: DevBoot.Consume(loaded));
                Assert.That(loaded, Is.EqualTo("SampleScene"));
                Assert.That(switcher.CurrentId, Is.EqualTo("second"));
                Assert.That(DevBoot.Consume(loaded), Is.Null);
            }
            finally { DevBoot.Consume("SampleScene"); }
        }

        [Test]
        public void LabAssemblyRequiresDevPlayerAndOptInOutsideEditor()
        {
            var package = PackageInfo.FindForAssembly(typeof(IExperiment).Assembly);
            var constraints = JsonUtility.FromJson<AssemblyDefinition>(File.ReadAllText(
                Path.Combine(package.resolvedPath, "Runtime", "YetiKit.Lab.asmdef"))).defineConstraints;
            CollectionAssert.AreEquivalent(new[] { "UNITY_EDITOR || DEVELOPMENT_BUILD", "UNITY_EDITOR || YETIKIT_DEV" }, constraints);
        }

        static ExperimentRegistry Registry(Func<string, IExperiment> make = null)
        {
            make ??= id => new Experiment(id);
            var registry = new ExperimentRegistry();
            registry.Add("first", () => make("first"));
            registry.Add("second", () => make("second"));
            return registry;
        }

        [Serializable]
        sealed class AssemblyDefinition { public string[] defineConstraints = null; }

        sealed class Store : IExperimentSelectionStore
        {
            readonly Dictionary<string, string> selections = new();
            public int Writes { get; private set; }
            public string Load(string labId) => selections.TryGetValue(labId, out var id) ? id : null;
            public void Save(string labId, string id) { selections[labId] = id; Writes++; }
        }

        sealed class Lease : IDisposable
        {
            readonly Action restore;
            public Lease(Action restore) => this.restore = restore;
            public void Dispose() => restore();
        }

        sealed class Hand : IHandInput
        {
            public Hand(bool right) => RightHand = right;
            public bool RightHand { get; }
            public HandMode Mode => HandMode.None;
            public bool HandTracked => false;
            public bool Present => false;
            public HandShape Shape => HandShape.Relaxed;
            public float Grip => 0;
            public float Trigger => 0;
            public bool Haptic(float amplitude, float seconds) => false;
        }

        sealed class Experiment : IExperiment
        {
            readonly List<string> events;
            readonly bool failRight;
            readonly Action<bool> onEnable;
            bool right;
            public Experiment(string id, List<string> events = null, bool failRight = false, Action<bool> onEnable = null)
            { Id = id; this.events = events; this.failRight = failRight; this.onEnable = onEnable; }
            public string Id { get; }
            public string Help => "Synthetic experiment";
            public void Initialize(IHandInput hand) { right = hand.RightHand; events?.Add($"init:{Id}:{right}"); }
            public void Enable()
            {
                events?.Add($"enable:{Id}");
                onEnable?.Invoke(right);
                if (failRight && right) throw new InvalidOperationException();
            }
            public void Disable() => events?.Add($"disable:{Id}");
            public void Dispose() => events?.Add($"dispose:{Id}");
            public void Tick(float now) => events?.Add($"tick:{Id}");
        }
    }
}
