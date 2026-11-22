using System;
using System.Collections.Generic;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("YetiKit.Playtest.XR.Tests")]

namespace YetiKit.Playtest.XR
{
    // Main-thread coordinator. Only live sessions are subscribed to producers.
    internal sealed class RecorderSession : IDisposable
    {
        const int DrainMs = 500;
        readonly FileChunkStore store;
        readonly ChunkPump pump;
        readonly Func<double> clock;
        readonly Func<DateTime> utc;
        readonly Func<string> sample;
        readonly IPlayerIdentity player;
        readonly IBuildIdentity build;
        readonly IFlightEventSource[] sources;
        readonly FixedRateSampler cadence = new FixedRateSampler(30);
        readonly List<IDisposable> registrations = new List<IDisposable>();
        FlightLog log;
        double nextBegin;
        long lastFrame;
        bool disposed;

        internal RecordingSession Session { get; private set; }

        internal RecorderSession(FileChunkStore store, Func<double> clock, Func<DateTime> utc, Func<string> sample,
            IPlayerIdentity player, IBuildIdentity build, IFlightEventSource[] sources)
        {
            this.store = store;
            this.clock = clock;
            this.utc = utc;
            this.sample = sample;
            this.player = player;
            this.build = build;
            this.sources = sources == null ? Array.Empty<IFlightEventSource>() : (IFlightEventSource[])sources.Clone();
            store.RecoverChunks();
            pump = new ChunkPump(store: store);
        }

        internal void Tick(long frame, double delta, bool paused)
        {
            if (disposed) return;
            lastFrame = frame;
            if (paused)
            {
                if (Session != null && !Session.Paused)
                {
                    Unsubscribe();
                    Session.Pause(frame, DrainMs);
                    cadence.Reset();
                }
                return;
            }
            if (Session?.Paused == true)
            {
                if (Session.Resume()) Subscribe();
                else End();
                delta = 0; // Don't count the frame that spans the pause.
            }
            if (Session == null)
            {
                if (!Begin(frame)) return;
                delta = 0;
            }
            if (cadence.Tick(delta)) log.AppendEvent("f", sample());
            Session.Tick(frame);
        }

        bool Begin(long frame)
        {
            var now = clock();
            if (now < nextBegin) return false;
            var id = SessionRules.NewId(utc(), Guid.NewGuid().GetHashCode());
            log = new FlightLog(clock, Classification.Instance);
            var next = new RecordingSession(log, pump, store, new SessionMeta(id, build: build, player: player), utc);
            if (!next.Begin(frame))
            {
                nextBegin = now + 1;
                UnityEngine.Debug.LogWarning("[Playtest XR] Could not create a session. Retrying in one second.");
                return false;
            }
            Session = next;
            cadence.Reset();
            Subscribe();
            return true;
        }

        void Subscribe()
        {
            foreach (var source in sources)
                if (source != null) registrations.Add(log.Register(source));
        }

        void Unsubscribe()
        {
            foreach (var registration in registrations) registration.Dispose();
            registrations.Clear();
        }

        void End()
        {
            Unsubscribe();
            Session?.End(lastFrame);
            Session = null;
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { End(); }
            finally { pump.Dispose(); }
        }

        sealed class Classification : IEventClassification
        {
            internal static readonly Classification Instance = new Classification();

            public EventClass Classify(string kind) => kind == "f" ? EventClass.Frame :
                kind == "throw" ? EventClass.Throw : EventClass.Meaningful;
        }
    }
}
