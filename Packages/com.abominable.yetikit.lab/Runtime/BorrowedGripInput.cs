using System;
using System.Collections.Generic;
using UnityEngine;
using YetiKit.Hands;

namespace YetiKit.Lab
{
    internal sealed class BorrowedGripInput : IDisposable
    {
        readonly Dictionary<Behaviour, bool> original = new Dictionary<Behaviour, bool>();
        bool restored;

        internal void Suppress(Behaviour[] inputs)
        {
            if (inputs == null) return;
            // Capture every input before OnDisable callbacks can change another input's state.
            foreach (var input in inputs)
                if (input) original.TryAdd(input, input is HandGrabInteractor hand ? hand.allowSelect : input.enabled);
            foreach (var input in original.Keys)
            {
                if (restored) return; // A component's OnDisable may end the session synchronously.
                Set(input, false);
            }
        }

        public void Dispose()
        {
            if (restored) return;
            restored = true;
            foreach (var pair in original)
                Set(pair.Key, pair.Value);
        }

        static void Set(Behaviour input, bool value)
        {
            if (!input) return;
            // PlayerHand re-enables its tracked interactor on every valid tracking update.
            if (input is HandGrabInteractor hand) hand.allowSelect = value;
            else input.enabled = value;
        }
    }
}
