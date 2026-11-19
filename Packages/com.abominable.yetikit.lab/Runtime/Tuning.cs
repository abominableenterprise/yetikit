using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace YetiKit.Lab
{
    public sealed class Tuning
    {
        private readonly string experimentId;
        private readonly ITuningStore store;
        private readonly List<ITuningBinding> bindings = new List<ITuningBinding>();
        private readonly Dictionary<string, float> values;
        private readonly bool rejectedDocument;
        // Null is clean; positive infinity means the next tick should start the debounce.
        private double? saveAt;
        public IReadOnlyList<ITuningBinding> Bindings { get; }

        public Tuning(string experimentId, ITuningStore store = null)
        {
            if (string.IsNullOrWhiteSpace(experimentId)) throw new ArgumentException("Experiment ID is required.", nameof(experimentId));
            this.experimentId = experimentId;
            this.store = store ?? new PlayerPrefsTuningStore();
            Bindings = bindings.AsReadOnly();
            var body = this.store.Load(experimentId);
            var loaded = Load(body);
            rejectedDocument = body != null && loaded == null;
            values = loaded ?? new Dictionary<string, float>(StringComparer.Ordinal);
        }

        public ITuningBinding Float(string id, Func<float> get, Action<float> set, float defaultValue,
            float min, float max, float step, string group = "") => Register(id, get, set, defaultValue, min, max, step, group, false);

        public ITuningBinding Bool(string id, Func<bool> get, Action<bool> set, bool defaultValue, string group = "") =>
            Register(id, get == null ? (Func<float>)null : () => get() ? 1f : 0f,
                set == null ? (Action<float>)null : x => set(x == 1f), defaultValue ? 1f : 0f, 0f, 1f, 1f, group, true);

        private ITuningBinding Register(string id, Func<float> get, Action<float> set, float fallback,
            float min, float max, float step, string group, bool isBool)
        {
            if (string.IsNullOrWhiteSpace(id) || bindings.Any(b => b.Id == id)) throw new ArgumentException("Binding ID must be nonempty and unique.", nameof(id));
            if (get == null || set == null) throw new ArgumentException("Binding getter and setter are required.");
            if (!Finite(min) || !Finite(max) || !Finite(step) || step <= 0f || !Finite(fallback) || fallback < min || fallback > max)
                throw new ArgumentException("Invalid binding range, default, or step.");
            // Snap interior values from min, while keeping exact defaults and endpoints selectable.
            float Constrain(float value) => value <= min || value >= max || value == fallback ? Mathf.Clamp(value, min, max) :
                Mathf.Clamp((float)(min + Math.Round(((double)value - min) / step, MidpointRounding.AwayFromZero) * step), min, max);
            void Apply(float value)
            {
                if (!Finite(value)) throw new ArgumentException("Binding value must be finite.", nameof(value));
                value = Constrain(value);
                if (get() != value) set(value);
                if (rejectedDocument) return; // Live edits only until the store is repaired and the model recreated.
                if (value == fallback ? !values.Remove(id) : values.TryGetValue(id, out var old) && old == value) return;
                if (value != fallback) values[id] = value;
                saveAt = double.PositiveInfinity;
            }
            if (values.TryGetValue(id, out var stored)) set(Constrain(stored));
            var binding = new Binding(id, group, fallback, min, max, step, isBool, get, Apply);
            bindings.Add(binding);
            return binding;
        }

        public void Reset(string id) => ResetWhere(b => b.Id == id);
        public void ResetGroup(string group) => ResetWhere(b => b.Group == group);
        public void ResetAll() => ResetWhere(b => true);
        private void ResetWhere(Func<ITuningBinding, bool> match)
        {
            foreach (var binding in bindings) if (match(binding)) binding.Set(binding.Default);
        }

        // Call each frame with monotonic, unscaled seconds; the first tick after an edit starts the quiet period.
        public void Tick(double now)
        {
            if (saveAt == double.PositiveInfinity) saveAt = now + 0.4d;
            if (now >= saveAt) Flush();
        }

        public void Flush()
        {
            if (!saveAt.HasValue) return;
            var entries = values.Select(p => new Entry { id = p.Key, value = p.Value }).ToArray();
            store.Save(experimentId, JsonUtility.ToJson(new Document { v = 1, values = entries }));
            saveAt = null;
        }

        private static Dictionary<string, float> Load(string body)
        {
            if (string.IsNullOrWhiteSpace(body)) return null;
            try
            {
                // Inspect token types before conversion: JsonUtility reads a missing float as zero.
                using var reader = new JsonTextReader(new StringReader(body)) { DateParseHandling = DateParseHandling.None };
                var doc = JObject.Load(reader);
                if (reader.Read() || !JToken.DeepEquals(doc["v"], new JValue(1)) || !(doc["values"] is JArray entries)) return null;
                var loaded = new Dictionary<string, float>(StringComparer.Ordinal);
                foreach (var entry in entries)
                {
                    if (!(entry is JObject row) || row["id"]?.Type != JTokenType.String) return null;
                    var id = (string)row["id"];
                    var number = row["value"];
                    if (string.IsNullOrWhiteSpace(id) || (number?.Type != JTokenType.Integer && number?.Type != JTokenType.Float)) return null;
                    var value = (float)number;
                    if (!Finite(value) || !loaded.TryAdd(id, value)) return null;
                }
                return loaded;
            }
            catch (JsonException) { return null; } // Unreadable JSON.
        }

        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        [Serializable] private sealed class Document { public int v; public Entry[] values; }
        [Serializable] private sealed class Entry { public string id; public float value; }

        private sealed class Binding : ITuningBinding
        {
            public string Id { get; }
            public string Group { get; }
            public float Default { get; }
            public float Min { get; }
            public float Max { get; }
            public float Step { get; }
            public bool IsBool { get; }
            private readonly Func<float> get;
            private readonly Action<float> set;
            public Binding(string id, string group, float fallback, float min, float max, float step, bool isBool, Func<float> get, Action<float> set) =>
                (Id, Group, Default, Min, Max, Step, IsBool, this.get, this.set) = (id, group, fallback, min, max, step, isBool, get, set);
            public float Get() => get();
            public void Set(float value) => set(value);
        }
    }
}
