using System;
using System.Collections.Generic;
using UnityEngine;
using Object = UnityEngine.Object;

namespace YetiKit.Lab
{
    public interface IInteractableCatalog
    {
        IReadOnlyList<InteractableEntry> Entries { get; }
    }

    public sealed class InteractableEntry
    {
        public readonly string Id, DisplayName, Category;
        public readonly GameObject Prefab;
        public readonly Func<GameObject> Spawn;

        public InteractableEntry(string id, string displayName, GameObject prefab, string category = null)
        {
            if (!prefab) throw new ArgumentNullException(nameof(prefab));
            Id = Required(id, nameof(id));
            DisplayName = Required(displayName, nameof(displayName));
            Category = category;
            Prefab = prefab;
            Spawn = () => Object.Instantiate(prefab);
        }

        /// <summary>The factory must return a fresh, active instance for the station to own.</summary>
        public InteractableEntry(string id, string displayName, Func<GameObject> spawn, string category = null)
        {
            Id = Required(id, nameof(id));
            DisplayName = Required(displayName, nameof(displayName));
            Category = category;
            Spawn = spawn ?? throw new ArgumentNullException(nameof(spawn));
        }

        static string Required(string value, string param) => !string.IsNullOrWhiteSpace(value) ? value
            : throw new ArgumentException("Must not be blank.", param);
    }

    public static class ReturnRules
    {
        public const float Delay = 3f;
        public static float Tick(float elapsed, bool held, float dt) => held ? 0 : elapsed + Mathf.Max(0, dt);
        public static bool Due(float elapsed) => elapsed >= Delay;
    }
}
