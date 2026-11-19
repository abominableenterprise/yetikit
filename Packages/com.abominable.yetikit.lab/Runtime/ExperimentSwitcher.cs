using System;
using YetiKit.Hands;

namespace YetiKit.Lab
{
    /// <summary>Owns just the selected pair and a lease on the input it borrows.</summary>
    public sealed class ExperimentSwitcher : IDisposable
    {
        readonly string labId;
        readonly ExperimentRegistry registry;
        readonly IHandInput[] hands;
        readonly IExperimentSelectionStore store;
        readonly Func<IDisposable> borrowInput;
        IDisposable inputLease;
        readonly IExperiment[] active = new IExperiment[2];
        readonly bool[] enabled = new bool[2];
        bool activating;
        bool disposed;

        public string CurrentId { get; private set; }
        public string Help => active[0]?.Help;

        public ExperimentSwitcher(string labId, ExperimentRegistry registry, IHandInput leftHand, IHandInput rightHand,
            IExperimentSelectionStore store = null, Func<IDisposable> borrowInput = null, string initialId = null)
        {
            if (string.IsNullOrWhiteSpace(labId)) throw new ArgumentException("A lab needs an id.", nameof(labId));
            this.labId = labId;
            this.registry = registry ?? throw new ArgumentNullException(nameof(registry));
            hands = new[] { leftHand ?? throw new ArgumentNullException(nameof(leftHand)),
                rightHand ?? throw new ArgumentNullException(nameof(rightHand)) };
            this.store = store ?? new PlayerPrefsExperimentSelectionStore();
            this.borrowInput = borrowInput;
            var id = registry.Resolve(initialId ?? this.store.Load(labId));
            if (id != null) Activate(id, registry.Factory(id));
        }

        public bool Select(string id)
        {
            if (disposed) throw new ObjectDisposedException(nameof(ExperimentSwitcher));
            var factory = registry.Factory(id);
            if (factory == null || activating) return false;
            if (CurrentId != id) Activate(id, factory);
            if (disposed) return false;
            store.Save(labId, id);
            return true;
        }

        public void Tick(float now)
        {
            if (disposed || activating) return;
            foreach (var experiment in active) experiment?.Tick(now);
        }

        void Activate(string id, Func<IExperiment> factory)
        {
            activating = true;
            try
            {
                Release();
                if (disposed) return;
                inputLease = borrowInput?.Invoke();
                if (disposed) return;
                for (int i = 0; i < active.Length; i++)
                {
                    var experiment = factory();
                    if (experiment == null || ReferenceEquals(active[0], experiment))
                        throw new InvalidOperationException("Experiment factories must return a fresh instance per hand.");
                    active[i] = experiment;
                    if (disposed) return;
                    if (experiment.Id != id) throw new InvalidOperationException("Experiment id does not match its registration.");
                    if (disposed) return;
                    experiment.Initialize(hands[i]);
                    if (disposed) return;
                    enabled[i] = true;
                    experiment.Enable();
                    if (disposed) return;
                }
                CurrentId = id;
            }
            finally
            {
                try { if (CurrentId == null) Release(); }
                finally { activating = false; }
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            // Activation owns cleanup after the current consumer callback returns.
            if (!activating) Release();
        }

        void Release()
        {
            var lease = inputLease;
            inputLease = null;
            CurrentId = null;
            try { Stop(0); }
            finally { try { Stop(1); } finally { lease?.Dispose(); } }
        }

        void Stop(int index)
        {
            var experiment = active[index];
            var disable = enabled[index];
            active[index] = null;
            enabled[index] = false;
            try { if (disable) experiment.Disable(); }
            finally { experiment?.Dispose(); }
        }
    }
}
