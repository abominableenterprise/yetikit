using System;
using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Interaction
{
    public interface IThrowTargetSource
    {
        IReadOnlyList<ThrowTarget> Targets { get; }
    }

    /// <summary>The optional target provider for throws that do not supply an explicit list.</summary>
    public static class ThrowTargetSource
    {
        static Registration current;
        public static IThrowTargetSource Current => current?.Source;

        /// <summary>Replace the current provider. Disposing an old registration leaves its replacement intact.</summary>
        public static IDisposable Register(IThrowTargetSource source) =>
            current = new Registration(source ?? throw new ArgumentNullException(nameof(source)));

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void Reset() => current = null;

        sealed class Registration : IDisposable
        {
            internal IThrowTargetSource Source { get; private set; }

            internal Registration(IThrowTargetSource source) => Source = source;

            public void Dispose()
            {
                if (ReferenceEquals(current, this)) Reset();
                Source = null;
            }
        }
    }
}
