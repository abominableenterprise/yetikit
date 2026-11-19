using System;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Lab.Tests
{
    public sealed class TuningTests
    {
        [Test]
        public void BindingsExposeOrderedMetadataAndConstrainLiveValues()
        {
            var tuning = new Tuning("sample", new MemoryStore());
            float offset = 0f;
            bool enabled = false;
            tuning.Float("offset", () => offset, x => offset = x, 0f, -1f, 1f, 0.25f, "motion");
            tuning.Bool("enabled", () => enabled, x => enabled = x, false);

            var dial = tuning.Bindings[0];
            Assert.That(dial.Id, Is.EqualTo("offset"));
            Assert.That(dial.Group, Is.EqualTo("motion"));
            Assert.That(dial.Default, Is.Zero);
            Assert.That(dial.Min, Is.EqualTo(-1f));
            Assert.That(dial.Max, Is.EqualTo(1f));
            Assert.That(dial.Step, Is.EqualTo(0.25f));
            Assert.That(dial.IsBool, Is.False);
            dial.Set(0.38f);
            Assert.That(offset, Is.EqualTo(0.5f));
            Assert.That(dial.Get(), Is.EqualTo(offset));
            dial.Set(20f);
            Assert.That(offset, Is.EqualTo(1f));
            dial.Set(-20f);
            Assert.That(offset, Is.EqualTo(-1f));
            Assert.Throws<ArgumentException>(() => dial.Set(float.NaN));
            Assert.That(offset, Is.EqualTo(-1f));

            var toggle = tuning.Bindings[1];
            Assert.That(toggle.Id, Is.EqualTo("enabled"));
            Assert.That(toggle.IsBool, Is.True);
            Assert.That(toggle.Step, Is.EqualTo(1f));
            toggle.Set(0.6f);
            Assert.That(enabled, Is.True);
            Assert.That(toggle.Get(), Is.EqualTo(1f));
            toggle.Set(0.4f);
            Assert.That(enabled, Is.False);
            Assert.That(toggle.Get(), Is.Zero);
        }

        [Test]
        public void ResetsRestoreOnlyTheRequestedKnownBindingsAndKeepUnknownValues()
        {
            var store = new MemoryStore();
            store.Bodies["sample"] = "{\"v\":1,\"values\":[{\"id\":\"later\",\"value\":3}]}";
            var tuning = new Tuning("sample", store);
            var first = Register(tuning, "first", "pair");
            var second = Register(tuning, "second", "pair");
            var third = Register(tuning, "third", "other");
            first.Set(1f);
            second.Set(2f);
            third.Set(3f);

            tuning.Reset("later");
            tuning.Reset("first");
            Assert.That(first.Get(), Is.Zero);
            Assert.That(second.Get(), Is.EqualTo(2f));
            Assert.That(third.Get(), Is.EqualTo(3f));
            first.Set(4f);
            tuning.ResetGroup("pair");
            Assert.That(first.Get(), Is.Zero);
            Assert.That(second.Get(), Is.Zero);
            Assert.That(third.Get(), Is.EqualTo(3f));
            tuning.ResetAll();
            Assert.That(third.Get(), Is.Zero);
            tuning.Flush();

            var reloaded = new Tuning("sample", store);
            Assert.That(Register(reloaded, "third").Get(), Is.Zero);
            Assert.That(Register(reloaded, "later").Get(), Is.EqualTo(3f));
        }

        [Test]
        public void ChangesDebounceAndFlushIsImmediateAndIdempotent()
        {
            var store = new MemoryStore();
            var tuning = new Tuning("sample", store);
            var dial = Register(tuning, "dial");
            tuning.Tick(0d);
            dial.Set(1f);
            tuning.Tick(0.1d);
            dial.Set(2f);
            tuning.Tick(0.3d);
            tuning.Tick(0.6d);
            Assert.That(store.Saves, Is.Zero);
            tuning.Tick(0.8d);
            Assert.That(store.Saves, Is.EqualTo(1));
            tuning.Tick(1d);
            dial.Set(2f);
            tuning.Flush();
            Assert.That(store.Saves, Is.EqualTo(1));
            dial.Set(3f);
            tuning.Flush();
            tuning.Flush();
            Assert.That(store.Saves, Is.EqualTo(2));
            Assert.That(Register(new Tuning("sample", store), "dial").Get(), Is.EqualTo(3f));
        }

        [Test]
        public void StoredValuesAreConstrainedAndIsolatedByExperiment()
        {
            var store = new MemoryStore();
            store.Bodies["alpha"] = "{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":20}]}";
            var alpha = new Tuning("alpha", store);
            var beta = new Tuning("beta", store);
            Assert.That(Register(alpha, "dial").Get(), Is.EqualTo(4f));
            var dial = Register(beta, "dial");
            Assert.That(dial.Get(), Is.Zero);
            alpha.Flush();
            Assert.That(store.Saves, Is.Zero);
            dial.Set(2f);
            beta.Flush();
            Assert.That(Register(new Tuning("alpha", store), "dial").Get(), Is.EqualTo(4f));
            Assert.That(Register(new Tuning("beta", store), "dial").Get(), Is.EqualTo(2f));
        }

        [Test]
        public void ResetRestoresExactDefaultEvenWhenItIsOffStep()
        {
            var store = new MemoryStore();
            var tuning = new Tuning("sample", store);
            float live = 0.3f;
            var dial = tuning.Float("dial", () => live, x => live = x, 0.3f, 0f, 1f, 0.25f);
            dial.Set(0.8f);
            tuning.Flush();
            tuning.Reset("dial");
            tuning.Flush();
            Assert.That(live, Is.EqualTo(0.3f));
            Assert.That(store.Bodies["sample"], Does.Not.Contain("dial"));
        }

        [TestCase("")]
        [TestCase("  ")]
        [TestCase("{broken")]
        [TestCase("{\"v\":2,\"values\":[{\"id\":\"dial\",\"value\":3}]}")]
        [TestCase("{\"values\":[{\"id\":\"dial\",\"value\":3}]}")]
        [TestCase("{\"v\":1}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":3},{\"value\":2}]}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":3},{\"id\":\"dial\",\"value\":2}]}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\"}]}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":3},{\"id\":\"other\"}]}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":null}]}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":\"0\"}]}")]
        [TestCase("{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":false}]}")]
        public void InvalidDocumentsStayUntouchedAfterEdits(string body)
        {
            var store = new MemoryStore();
            store.Bodies["sample"] = body;
            var tuning = new Tuning("sample", store);
            float live = 1f;
            var dial = tuning.Float("dial", () => live, x => live = x, 0f, 0f, 4f, 1f);
            Assert.That(live, Is.EqualTo(1f));

            dial.Set(2f);
            Assert.That(live, Is.EqualTo(2f));
            tuning.Tick(0d);
            tuning.Tick(1d);
            Assert.That(store.Saves, Is.Zero, "Debounced save must not overwrite a rejected document.");

            dial.Set(4f);
            tuning.Flush();
            tuning.ResetAll();
            tuning.Flush();
            Assert.That(live, Is.Zero);
            Assert.That(store.Saves, Is.Zero);
            Assert.That(store.Bodies["sample"], Is.EqualTo(body));
        }

        [Test]
        public void ExplicitZeroLoadsAndAllowsOtherBindingsToSave()
        {
            var store = new MemoryStore();
            store.Bodies["sample"] = "{\"v\":1,\"values\":[{\"id\":\"dial\",\"value\":0}]}";
            var tuning = new Tuning("sample", store);
            float live = 1f;
            tuning.Float("dial", () => live, x => live = x, 1f, 0f, 4f, 1f);
            Assert.That(live, Is.Zero);

            Register(tuning, "other").Set(2f);
            tuning.Flush();
            Assert.That(store.Saves, Is.EqualTo(1));
            var reloaded = new Tuning("sample", store);
            Assert.That(Register(reloaded, "other").Get(), Is.EqualTo(2f));
        }

        [Test]
        public void DefaultStoreSavesMissingDocumentsButPreservesStoredEmptyStrings()
        {
            var experimentId = Guid.NewGuid().ToString("N");
            var key = "YetiKit.Lab.Tuning." + experimentId;
            try
            {
                var tuning = new Tuning(experimentId);
                Register(tuning, "dial").Set(1f);
                tuning.Flush();
                Assert.That(Register(new Tuning(experimentId), "dial").Get(), Is.EqualTo(1f));

                PlayerPrefs.SetString(key, "");
                tuning = new Tuning(experimentId);
                Register(tuning, "dial").Set(2f);
                tuning.Flush();
                Assert.That(PlayerPrefs.GetString(key, "missing"), Is.Empty);
            }
            finally
            {
                PlayerPrefs.DeleteKey(key);
                PlayerPrefs.Save();
            }
        }

        private static ITuningBinding Register(Tuning tuning, string id, string group = "")
        {
            float live = 0f;
            return tuning.Float(id, () => live, x => live = x, 0f, 0f, 4f, 1f, group);
        }

        private sealed class MemoryStore : ITuningStore
        {
            public readonly Dictionary<string, string> Bodies = new Dictionary<string, string>();
            public int Saves { get; private set; }

            public string Load(string experimentId) => Bodies.TryGetValue(experimentId, out var body) ? body : null;

            public void Save(string experimentId, string body)
            {
                Bodies[experimentId] = body;
                Saves++;
            }
        }
    }
}
