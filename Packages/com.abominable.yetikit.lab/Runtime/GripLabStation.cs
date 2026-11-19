using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Events;
using UnityEngine.UI;
using YetiKit.Interaction;

namespace YetiKit.Lab
{
    [DisallowMultipleComponent]
    public sealed class GripLabStation : MonoBehaviour
    {
        public Button reset, back;
        [SerializeField] Transform head;
        [SerializeField, Min(0.24f)] float tableWidth = 2.8f;
        [SerializeField] UnityEvent backRequested = new UnityEvent();
        GripLabSlot[] slots;

        public UnityEvent BackRequested => backRequested;
        public Transform Head { get => head; set => head = value; }
        public GripLabFlightEventSource FlightEvents { get; } = new GripLabFlightEventSource();

        /// <summary>Populate once, with the station origin at the center of the table's near edge.</summary>
        public void Populate(IInteractableCatalog catalog)
        {
            if (!isActiveAndEnabled) throw new InvalidOperationException("The station must be active.");
            if (slots != null) throw new InvalidOperationException("The station already owns a catalog.");
            var entries = catalog?.Entries ?? throw new ArgumentNullException(nameof(catalog));
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in entries)
                if (entry == null || !ids.Add(entry.Id))
                    throw new ArgumentException("Entries must be non-null and have unique IDs.", nameof(catalog));

            var spawned = new List<GameObject>(entries.Count);
            slots = new GripLabSlot[entries.Count];
            try
            {
                for (var i = 0; i < entries.Count; i++)
                {
                    var entry = entries[i];
                    var item = entry.Spawn();
                    if (!item) throw new InvalidOperationException($"Catalog entry '{entry.Id}' did not spawn a prop.");
                    spawned.Add(item);
                    item.transform.SetParent(transform, true);
                    if (!item.TryGetComponent<GrabbableProp>(out var prop) || !prop.isActiveAndEnabled ||
                        item.GetComponent<GripLabSlot>())
                        throw new InvalidOperationException($"Catalog entry '{entry.Id}' must spawn an active prop without a lab slot.");
                    item.name = entry.DisplayName;
                    var slot = item.AddComponent<GripLabSlot>();
                    slot.Configure(this, entry);
                    slots[i] = slot;
                }
                GripLabLayout.Arrange(slots, transform.position, tableWidth);
            }
            catch
            {
                foreach (var item in spawned)
                {
                    item.SetActive(false);
                    Destroy(item);
                }
                slots = null;
                throw;
            }
        }

        void OnEnable()
        {
            if (reset) reset.onClick.AddListener(ResetAll);
            if (back) back.onClick.AddListener(Back);
        }

        void OnDisable()
        {
            if (reset) reset.onClick.RemoveListener(ResetAll);
            if (back) back.onClick.RemoveListener(Back);
        }

        void Update() => Tick(Time.deltaTime);

        public void Tick(float dt)
        {
            if (slots == null) return;
            foreach (var slot in slots) if (slot) slot.Tick(dt);
        }

        public void ResetAll()
        {
            if (slots == null) return;
            foreach (var slot in slots) if (slot) slot.ReturnHome();
        }

        public void Back()
        {
            ResetAll();
            backRequested.Invoke();
        }
    }
}
