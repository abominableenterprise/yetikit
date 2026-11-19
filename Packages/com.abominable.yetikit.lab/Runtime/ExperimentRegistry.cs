using System;
using System.Collections.Generic;

namespace YetiKit.Lab
{
    /// <summary>Factories in registration order. Each invocation must create a fresh instance for one hand.</summary>
    public sealed class ExperimentRegistry
    {
        readonly List<Entry> entries = new();

        public int Count => entries.Count;
        public string IdAt(int index) => entries[index].Id;

        public IDisposable Add(string id, Func<IExperiment> factory)
        {
            if (string.IsNullOrWhiteSpace(id)) throw new ArgumentException("An experiment needs an id.", nameof(id));
            if (factory == null) throw new ArgumentNullException(nameof(factory));
            if (Find(id) != null) throw new ArgumentException("Experiment id already registered.", nameof(id));
            var entry = new Entry(this, id, factory);
            entries.Add(entry);
            return entry;
        }

        public string Resolve(string id) => Find(id)?.Id ?? (Count == 0 ? null : IdAt(0));
        internal Func<IExperiment> Factory(string id) => Find(id)?.Factory;
        internal void Clear() => entries.Clear();
        Entry Find(string id) => entries.Find(entry => entry.Id == id);

        sealed class Entry : IDisposable
        {
            readonly ExperimentRegistry owner;
            public readonly string Id;
            public readonly Func<IExperiment> Factory;
            public Entry(ExperimentRegistry owner, string id, Func<IExperiment> factory)
            { this.owner = owner; Id = id; Factory = factory; }
            public void Dispose() => owner.entries.Remove(this);
        }
    }
}
