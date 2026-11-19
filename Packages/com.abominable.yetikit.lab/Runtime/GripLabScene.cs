using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using UnityEngine;

[assembly: InternalsVisibleTo("YetiKit.Lab.Editor")]

namespace YetiKit.Lab
{
    /// <summary>Connects a baked Grip Lab scene to its runtime station.</summary>
    [DisallowMultipleComponent]
    [RequireComponent(typeof(GripLabStation))]
    public sealed class GripLabScene : MonoBehaviour
    {
        [Serializable]
        internal struct BakedProp
        {
            public string Id, DisplayName, Category;
            public GameObject Instance;
        }

        sealed class Catalog : IInteractableCatalog
        {
            public IReadOnlyList<InteractableEntry> Entries { get; }
            public Catalog(InteractableEntry[] entries) => Entries = entries;
        }

        [SerializeField] GripLabStation station;
        [SerializeField] Transform table;
        [SerializeField] BakedProp[] props = Array.Empty<BakedProp>();

        internal void Configure(GripLabStation owner, Transform surface, BakedProp[] baked)
        {
            station = owner;
            table = surface;
            props = baked;
        }

        void Start()
        {
            var entries = new InteractableEntry[props.Length];
            for (var i = 0; i < entries.Length; i++)
            {
                var prop = props[i];
                var instance = prop.Instance;
                if (!instance || instance.transform.parent != station.transform)
                    throw new InvalidOperationException($"Baked prop '{prop.Id}' must be a child of the station.");
                entries[i] = new InteractableEntry(prop.Id, prop.DisplayName, () => instance, prop.Category);
            }
            station.Populate(new Catalog(entries));
            FitTable();
        }

        void FitTable()
        {
            Physics.SyncTransforms();
            var near = station.transform.position;
            var size = table.localScale;
            var farX = near.x + size.x / 2f;
            var farZ = near.z + size.z;
            const float Margin = 0.12f;
            foreach (var prop in props)
            foreach (var collider in prop.Instance.GetComponent<GripLabSlot>().Solids)
            {
                if (!collider || !collider.enabled || !collider.gameObject.activeInHierarchy) continue;
                var max = collider.bounds.max;
                farX = Mathf.Max(farX, max.x + Margin);
                farZ = Mathf.Max(farZ, max.z + Margin);
            }

            // Widen toward +X for an oversized prop without moving the layout's near/left edges.
            var extraWidth = farX - (near.x + size.x / 2f);
            size.x += extraWidth;
            size.z = farZ - near.z;
            table.localScale = size;
            table.position = new Vector3(near.x + extraWidth / 2f, table.position.y, near.z + size.z / 2f);
        }
    }
}
