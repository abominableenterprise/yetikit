using System;
using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Lab
{
    internal sealed class BorrowedGripInput : IDisposable
    {
        readonly Dictionary<Behaviour, bool> original = new Dictionary<Behaviour, bool>();
        bool restored;

        internal void Suppress(Behaviour[] inputs)
        {
            if (inputs == null) return;
            foreach (var input in inputs)
            {
                if (restored) return; // A component's OnDisable may end the session synchronously.
                if (input && original.TryAdd(input, input.enabled)) input.enabled = false;
            }
        }

        public void Dispose()
        {
            if (restored) return;
            restored = true;
            foreach (var pair in original)
                if (pair.Key) pair.Key.enabled = pair.Value;
            original.Clear();
        }
    }
}
