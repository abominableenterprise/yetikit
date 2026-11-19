using System;
using UnityEngine;

namespace YetiKit.Lab
{
    public static class Experiments
    {
        public static ExperimentRegistry Registry { get; } = new();
        public static IDisposable Add(string id, Func<IExperiment> factory) => Registry.Add(id, factory);

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void Reset() => Registry.Clear();
    }
}
