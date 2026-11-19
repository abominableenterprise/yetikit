using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace YetiKit.Playtest
{
    /// <summary>
    /// One recording session's life on disk (main thread, one active session per log/pump pair).
    /// <see cref="Begin"/> creates a session directory and queues meta.json;
    /// <see cref="Tick"/> hands off lines to the pump every second and publishes chunks every 60 s; <see cref="Pause"/> publishes everything and rewrites
    /// meta.json; <see cref="End"/> also writes the done marker, only once the final meta.json is on disk
    /// (<see cref="ChunkPump.Finish"/>), or deletes a session too short to keep. The main
    /// thread only formats text and swaps buffers (<see cref="LastHandoffMs"/> / <see cref="MaxHandoffMs"/> measure it).
    /// </summary>
    public sealed class RecordingSession
    {
        public const double RotateSeconds = 60, HandoffSeconds = 1;

        readonly FlightLog log;
        readonly ChunkPump pump;
        readonly IChunkStore paths;
        readonly Func<DateTime> utcNow;
        readonly Action<string> createDir;
        public readonly SessionMeta Meta;
        double lastRotate, lastHandoff;
        long frameOrigin;

        /// <param name="createDir">Optional fault injection hook before the store creates the session directory.</param>
        public RecordingSession(FlightLog log, ChunkPump pump, IChunkStore paths, SessionMeta meta, Func<DateTime> utcNow,
            Action<string> createDir = null)
        {
            this.createDir = createDir;
            this.log = log;
            this.pump = pump;
            this.paths = paths;
            this.utcNow = utcNow;
            Meta = meta;
        }

        public string Id => Meta.Session;
        public string Dir => paths.SessionOutbox(Meta.Session);
        public bool Begun { get; private set; }
        public bool Ended { get; private set; }
        public bool Paused { get; private set; }
        DateTime pausedAt;
        public double LastHandoffMs { get; private set; }
        public double MaxHandoffMs { get; private set; }
        public int Handoffs { get; private set; }

        /// <summary>Is this session worth keeping (long enough, or something happened)?</summary>
        public bool Keep => SessionRules.Keep(Elapsed, log.Meaningful);

        /// <summary>Play time: <c>t</c> minus every pause (a headset-off break is not play time).</summary>
        double Elapsed => (Paused ? pausedSeconds : log.Now) - pausedTotal;
        double pausedSeconds, pausedTotal;

        /// <summary>
        /// Start: the directory, then t = 0, meta.json and a <c>start</c> line. All or nothing: when the directory
        /// cannot be made (IO error), nothing has changed (no clock restart, no pump job) and it returns false; call it
        /// again later.
        /// </summary>
        public bool Begin(long frameCount)
        {
            if (Ended) return false;
            if (Begun) return true;
            try
            {
                createDir?.Invoke(Dir);
                paths.CreateSession(Id);
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                LastBeginError = e.Message;
                return false;
            }
            Begun = true;
            LastBeginError = null;
            frameOrigin = frameCount;
            Meta.StartUtc = utcNow();
            Meta.EndUtc = null;
            pump.StartSession(Dir);
            lock (log.Gate)
            {
                log.Restart();
                WriteMeta();
                var sb = log.BeginLine("start", EventClass.Bookkeeping);
                JsonLine.Field(sb, "session", Meta.Session);
                JsonLine.Field(sb, "scene", Meta.Scene);
                JsonLine.End(sb);
            }
            return true;
        }

        /// <summary>Why the last <see cref="Begin"/> failed (null: it never did).</summary>
        public string LastBeginError { get; private set; }

        /// <summary>The per-frame tick: hand the buffer over every second, publish a chunk every minute.</summary>
        public void Tick(long frameCount)
        {
            if (!Begun || Ended || Paused) return;
            var now = log.Now;
            Meta.Frames = frameCount - frameOrigin;
            if (now - lastHandoff >= HandoffSeconds)
            {
                lastHandoff = now;
                Handoff();
            }
            if (now - lastRotate >= RotateSeconds)
            {
                lastRotate = now;
                pump.Rotate();
                WriteMeta();
            }
        }

        /// <summary>Hand the buffered lines to the pump thread: a buffer swap, no copy (the pump gzips them).</summary>
        void Handoff()
        {
            var start = Stopwatch.GetTimestamp();
            StringBuilder full = null;
            lock (log.Gate)
                if (log.Buffer.Length > 0) full = log.Swap(pump.TakeBuilder());
            pump.Write(full);
            LastHandoffMs = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
            Handoffs++;
            if (LastHandoffMs > MaxHandoffMs) MaxHandoffMs = LastHandoffMs;
        }

        /// <summary>The app is paused (headset off): everything to disk, meta.json with the time so far.</summary>
        public void Pause(long frameCount, int drainMs)
        {
            if (!Begun || Ended || Paused) return;
            lock (log.Gate) JsonLine.End(log.BeginLine("pause", EventClass.Bookkeeping));
            Paused = true;
            pausedAt = utcNow();
            pausedSeconds = log.Now;
            Flush(frameCount, pausedAt);
            pump.Drain(drainMs);
        }

        /// <summary>Back from a pause: true when this session goes on (a short pause), false when it must end and a
        /// new one start (<see cref="SessionRules.NewSessionOnResume"/>).</summary>
        public bool Resume()
        {
            if (Ended || !Begun) return false;
            if (!Paused) return true;
            var gap = (utcNow() - pausedAt).TotalSeconds;
            if (SessionRules.NewSessionOnResume(gap)) return false;
            Paused = false;
            pausedTotal += Math.Max(0, log.Now - pausedSeconds);
            Meta.EndUtc = null;
            lock (log.Gate)
            {
                var sb = log.BeginLine("resume", EventClass.Bookkeeping);
                JsonLine.Field(sb, "paused", gap, 1);
                JsonLine.End(sb);
            }
            return true;
        }

        /// <summary>
        /// The session is over: the last chunk, then the final meta.json and the done marker (written only once
        /// that meta.json is on disk, retried until it is), or the whole directory
        /// deleted when the session was too short and empty. The pump owns the session's outbox until then
        /// (<see cref="ChunkPump.Owns"/>). True when kept.
        /// </summary>
        public bool End(long frameCount)
        {
            if (Ended) return Kept;
            if (!Begun)
            {
                Ended = true;
                return Kept = false;
            }
            log.Seal();
            var at = Paused ? pausedAt : utcNow();
            Kept = Keep;
            Ended = true;
            if (!Kept)
            {
                Flush(frameCount, at, true);
                pump.DeleteDir(Dir, Meta.Session);
                return false;
            }
            Flush(frameCount, at, true);
            var meta = MetaBytes();
            var m = Meta.Copy();
            pump.Finish(Meta.Session, Path.Combine(Dir, FileChunkStore.MetaFile), meta, Path.Combine(Dir, DoneMarker.FileName), lost =>
            {
                m.Lost = lost;
                return Encoding.UTF8.GetBytes(new DoneMarker { session = m.Session, player = m.Player, build = m.Build, context = m.Context() }.ToJson());
            });
            return true;
        }

        public bool Kept { get; private set; }

        // final: the session's end writes its meta.json itself (with the done marker, ChunkPump.Finish).
        void Flush(long frameCount, DateTime end, bool final = false)
        {
            if (!Paused || Meta.EndUtc == null) Meta.Frames = frameCount - frameOrigin;
            Handoff();
            pump.Rotate();
            Meta.EndUtc = end;
            if (!final) WriteMeta();
            lastRotate = log.Now;
        }

        void WriteMeta() => pump.WriteFile(Path.Combine(Dir, FileChunkStore.MetaFile), MetaBytes());

        // meta.json is made on the pump thread, from a copy, so its lost is exact (see ChunkPump.WriteFile).
        Func<long, byte[]> MetaBytes()
        {
            var counts = new StringBuilder(256);
            lock (log.Gate)
            {
                Meta.Seconds = Elapsed;
                Meta.Samples = log.Samples;
                Meta.Events = log.Events;
                Meta.Throws = log.Throws;
                Meta.Errors = log.Errors;
                log.AppendCounts(counts);
            }
            var c = counts.ToString();
            var m = Meta.Copy();
            return lost =>
            {
                m.Lost = lost;
                return Encoding.UTF8.GetBytes(m.ToJson(sb => sb.Append(c)));
            };
        }
    }
}
