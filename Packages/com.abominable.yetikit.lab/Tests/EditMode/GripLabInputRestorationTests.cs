using System;
using System.Collections;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;
using UnityEngine.XR.Interaction.Toolkit;
using YetiKit.Hands;
using YetiKit.Interaction;

namespace YetiKit.Lab.Tests
{
    public sealed class GripLabInputRestorationTests
    {
        [UnityTest]
        public IEnumerator OnEnableCannotBeginUntilBorrowedInputIsRestored()
        {
            yield return new EnterPlayMode();
            var root = new GameObject("Synthetic station");
            try
            {
                root.AddComponent<XRInteractionManager>();
                var station = root.AddComponent<GripLabStation>();
                station.Populate(new Catalog());
                var slot = root.GetComponentInChildren<GripLabSlot>();
                var adjuster = station.Adjuster;
                var first = root.AddComponent<CompetingInput>();
                var second = root.AddComponent<CompetingInput>();
                var initiallyDisabled = root.AddComponent<CompetingInput>();
                initiallyDisabled.enabled = false;

                adjuster.Begin(slot, HandMode.Controller, first, second, initiallyDisabled);
                Assert.That(first.enabled, Is.False);
                Assert.That(second.enabled, Is.False);
                var attempts = 0;
                first.Enabled = () =>
                {
                    first.Enabled = null;
                    attempts++;
                    adjuster.Begin(slot, HandMode.Controller, second, initiallyDisabled);
                };

                adjuster.End();

                Assert.That(attempts, Is.EqualTo(1), "Restoration must exercise the real OnEnable callback.");
                Assert.Throws<InvalidOperationException>(adjuster.Undo,
                    "A restoration callback must not acquire a lease over partially restored inputs.");
                Assert.That(first.enabled, Is.True);
                Assert.That(second.enabled, Is.True);
                Assert.That(initiallyDisabled.enabled, Is.False);

                adjuster.Begin(slot, HandMode.Controller, first, second, initiallyDisabled);
                Assert.That(first.enabled, Is.False);
                Assert.That(second.enabled, Is.False, "The old lease must not interfere with the next adjustment.");
                adjuster.End();
                Assert.That(first.enabled, Is.True);
                Assert.That(second.enabled, Is.True);
                Assert.That(initiallyDisabled.enabled, Is.False);
            }
            finally { UnityEngine.Object.DestroyImmediate(root); }
            yield return new ExitPlayMode();
        }

        public sealed class CompetingInput : MonoBehaviour
        {
            public Action Enabled;
            void OnEnable() => Enabled?.Invoke();
        }

        sealed class Catalog : IInteractableCatalog
        {
            public IReadOnlyList<InteractableEntry> Entries { get; } = new[]
            {
                new InteractableEntry("block", "Block", MakeProp)
            };

            static GameObject MakeProp()
            {
                var item = new GameObject("Synthetic prop");
                item.AddComponent<BoxCollider>();
                item.AddComponent<GrabbableProp>();
                return item;
            }
        }
    }
}
