using System;
using YetiKit.Hands;

namespace YetiKit.Lab
{
    /// <summary>A fresh instance per hand; ticks only after initialization and enablement.</summary>
    public interface IExperiment : IDisposable
    {
        string Id { get; }
        string Help { get; }
        void Initialize(IHandInput hand);
        void Enable();
        void Disable();
        void Tick(float now);
    }
}
