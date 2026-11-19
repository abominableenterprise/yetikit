using System;
using UnityEngine;
using YetiKit.Hands;
using YetiKit.Interaction;

namespace YetiKit.Lab
{
    /// <summary>Edits one station prop and mode at a time. Committed undo history lasts until the station is destroyed.</summary>
    public sealed class GripLabAdjuster
    {
        readonly GripLabStation station;
        GripLabSlot slot;
        GripOverrideEntry entry;
        BorrowedGripInput borrowed;

        internal GripLabAdjuster(GripLabStation station) => this.station = station;

        /// <summary>Discard any previous preview, then suppress the supplied input components until End.
        /// Tracked-hand interactors are gated at selection so tracking can continue.
        /// Supply only competing input handlers, not the interactor that owns the current hold.</summary>
        public void Begin(GripLabSlot target, HandMode mode, params Behaviour[] inputs)
        {
            End();
            if (!station || !station.isActiveAndEnabled)
                throw new InvalidOperationException("The station must be active.");
            if (!target || !target.isActiveAndEnabled || target.Station != station)
                throw new ArgumentException("Pick an active slot on this station.", nameof(target));
            entry = target.OverrideFor(mode);
            slot = target;
            borrowed = new BorrowedGripInput();
            Run(_ => borrowed.Suppress(inputs));
        }

        /// <summary>Apply a live preview without saving it.</summary>
        public void Stage(GripProfile profile) => Run(e => e.Stage(profile));
        /// <summary>Save the preview for this prop and mode.</summary>
        public void Commit() => Run(e => e.Commit());
        /// <summary>Discard a preview, or restore and save the previous committed state.</summary>
        public void Undo() => Run(e => e.Undo());
        /// <summary>Remove the override for this prop and mode, reverting to the baked or authored grip.</summary>
        public void Reset() => Run(e => e.Reset());

        /// <summary>Discard a preview and restore borrowed input without changing committed overrides.</summary>
        public void End()
        {
            var previous = entry;
            var input = borrowed;
            slot = null;
            entry = null;
            borrowed = null;
            try { previous?.DiscardPreview(); }
            finally { input?.Dispose(); }
        }

        internal void End(GripLabSlot target) { if (slot == target) End(); }

        void Run(Action<GripOverrideEntry> edit)
        {
            if (entry == null) throw new InvalidOperationException("Begin an adjustment first.");
            try { edit(entry); }
            catch (Exception error)
            {
                try { End(); }
                catch (Exception cleanup) { throw new AggregateException(error, cleanup); }
                throw;
            }
        }
    }
}
