using System;
using System.Collections.Generic;
using YetiKit.Hands;
using YetiKit.Interaction;

namespace YetiKit.Lab
{
    // One edit history per spawned prop and mode; only the committed profile is persisted.
    internal sealed class GripOverrideEntry
    {
        readonly GrabbableProp prop;
        readonly string id;
        readonly HandMode mode;
        readonly IGripOverrideStore store;
        readonly bool readOnly;
        readonly Stack<GripProfile> history = new Stack<GripProfile>();
        GripProfile committed, preview;

        internal GripOverrideEntry(GrabbableProp prop, string id, HandMode mode, IGripOverrideStore store)
        {
            (this.prop, this.id, this.mode, this.store) = (prop, id, mode, store);
            readOnly = !GripOverrideDocument.TryRead(store?.Load(id, mode), out committed);
            if (committed != null) Apply(committed);
        }

        internal void Stage(GripProfile profile)
        {
            if (!GripOverrideDocument.Valid(profile))
                throw new ArgumentException("A valid grip spec is required.", nameof(profile));
            preview = new GripProfile(profile.id, profile.spec);
            Apply(preview);
        }

        internal void Commit()
        {
            if (preview != null) Replace(preview);
        }

        internal void Undo()
        {
            if (preview != null) DiscardPreview();
            else if (history.Count != 0)
            {
                var previous = history.Peek();
                Save(previous);
                committed = history.Pop();
                Apply(committed);
            }
        }

        internal void Reset() => Replace(null);

        void Replace(GripProfile next)
        {
            if (readOnly) throw new InvalidOperationException("The stored grip document is unreadable or unsupported.");
            if (!SameProfile(next, committed))
            {
                Save(next);
                history.Push(committed);
                committed = next;
            }
            preview = null;
            Apply(committed);
        }

        internal void DiscardPreview()
        {
            if (preview == null) return;
            preview = null;
            Apply(committed);
        }

        void Save(GripProfile profile) => store?.Save(id, mode, GripOverrideDocument.Write(profile));
        void Apply(GripProfile profile) { if (prop) prop.SetDevelopmentGrip(mode, profile); }
        static bool SameProfile(GripProfile a, GripProfile b) => a == b ||
            a != null && b != null && a.id == b.id && a.spec.Equals(b.spec);
    }
}
