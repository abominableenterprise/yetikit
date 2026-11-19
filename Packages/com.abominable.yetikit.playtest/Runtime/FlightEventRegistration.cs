using System;
using System.Collections.Generic;
using UnityEngine;

namespace YetiKit.Playtest
{
    public interface IFlightEventSource
    {
        /// <summary>Kind and payload, as accepted by <see cref="FlightLog.AppendEvent"/>.</summary>
        event Action<string, string> Event;
    }

    // Registration and disposal are main-thread operations. An in-flight callback may finish after disposal.
    internal sealed class FlightEventRegistration : IDisposable
    {
        static readonly HashSet<FlightEventRegistration> Active = new HashSet<FlightEventRegistration>();
        readonly IFlightEventSource source;
        readonly FlightLog log;
        volatile bool disposed;

        FlightEventRegistration(FlightLog log, IFlightEventSource source)
        {
            this.log = log;
            this.source = source;
            source.Event += Forward;
        }

        internal static IDisposable Attach(FlightLog log, IFlightEventSource source)
        {
            if (source == null) throw new ArgumentNullException(nameof(source));
            var registration = new FlightEventRegistration(log, source);
            Active.Add(registration);
            return registration;
        }

        void Forward(string kind, string payload)
        {
            if (!disposed) log.AppendEvent(kind, payload);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            Active.Remove(this);
            source.Event -= Forward;
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void Reset()
        {
            foreach (var registration in new List<FlightEventRegistration>(Active)) registration.Dispose();
        }
    }
}
