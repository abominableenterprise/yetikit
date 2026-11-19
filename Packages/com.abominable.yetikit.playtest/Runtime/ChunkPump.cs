using System;
using System.Collections.Concurrent;
using System.Threading;
using YetiKit.Core;

namespace YetiKit.Playtest
{
    /// <summary>
    /// The recorder's background thread: takes whole line buffers from the main thread (<see cref="Write"/> hands over
    /// the builder itself, no copy; <see cref="TakeBuilder"/> gives back an emptied one), gzips them into the session's chunk (<see cref="ChunkWriter"/>), and finishes chunks and writes
    /// files on request, so no compression or disk IO ever runs on the main thread. Errors are counted, never thrown.
    /// </summary>
    public sealed class ChunkPump : IDisposable
    {
        public const int BlockChars = 32 * 1024;
        public const int PooledBuilders = 3;

        enum Op { Text, Rotate, File, Session, Barrier, Delete, Finish }

        struct Job
        {
            public Op Op;
            public System.Text.StringBuilder Text;
            public string Path;
            public byte[] Bytes;
            public ManualResetEventSlim Done;
            public Func<long, byte[]> Make; // File: the bytes, given the session's Lost when the job runs
            public string Path2;            // Finish: the done marker
            public Func<long, byte[]> Make2;
            public string Owner;            // Finish, Delete: the session id it owns until it ran
        }

        /// <summary>A session's final meta.json and done marker, written in that order; kept and retried until both are.</summary>
        sealed class Ending
        {
            public string Owner, MetaPath, MarkerPath;
            public byte[] Meta, Marker; // Meta: null once it is on disk
            public int Failures;
            public double NextAt;
        }

        readonly ConcurrentQueue<Job> jobs = new ConcurrentQueue<Job>();
        readonly ConcurrentBag<System.Text.StringBuilder> pool = new ConcurrentBag<System.Text.StringBuilder>();
        readonly char[] block = new char[BlockChars]; // pump thread only
        readonly AutoResetEvent wake = new AutoResetEvent(false);
        readonly Thread thread;
        volatile bool stopping;
        ChunkWriter writer;
        string sessionDir; // pump thread only: the session a failed writer start is retried for
        long dropped;               // pump thread only: this session's text that had no writer
        long lost;
        readonly System.Collections.Generic.List<(string, string)> unpublished = new System.Collections.Generic.List<(string, string)>();
        readonly IChunkStore store;
        readonly Func<string, int> nextFree;
        readonly Func<string, System.IO.Stream> openFile;
        readonly Action<string, byte[]> writeFile;
        readonly Func<double> clock;
        readonly System.Collections.Generic.List<Ending> endings = new System.Collections.Generic.List<Ending>(); // pump thread only
        readonly System.Collections.Generic.Dictionary<string, int> owned = new System.Collections.Generic.Dictionary<string, int>(); // lock it

        /// <summary>Raised on the pump thread with the session dir and file name of each finished chunk.</summary>
        public event Action<string> ChunkWritten;
        public int Errors;
        public string LastError;
        /// <summary>Chars queued so far (the uncompressed size, for the budget numbers).</summary>
        public long RawChars;
        /// <summary>The current session's text that never reached a whole chunk (uncompressed bytes, about), after the
        /// jobs run so far (<see cref="Drain"/> first for an exact number). 0 when the recording is complete.</summary>
        public long Lost => Interlocked.Read(ref lost);

        /// <param name="nextFree">The first chunk number of a session (tests inject a failing one).</param>
        /// <param name="openFile">Creates a chunk file (tests inject a failing disk).</param>
        /// <param name="writeFile">Writes a small file atomically (defaults to the store).</param>
        /// <param name="clock">Seconds, for the retry backoff of a session's final files (tests use a fake one).</param>
        /// <param name="store">Session file operations (defaults to disk).</param>
        public ChunkPump(Func<string, int> nextFree = null, Func<string, System.IO.Stream> openFile = null,
            Action<string, byte[]> writeFile = null, Func<double> clock = null, IChunkStore store = null)
        {
            this.store = store ?? FileChunkStore.Default;
            this.openFile = openFile;
            this.writeFile = writeFile ?? this.store.PublishFile;
            this.clock = clock ?? (() => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency);
            this.nextFree = nextFree ?? this.store.NextFree;
            for (var i = 0; i < PooledBuilders; i++) pool.Add(new System.Text.StringBuilder(FlightLog.InitialChars));
            thread = new Thread(Run) { IsBackground = true, Name = "FlightRecorder", Priority = ThreadPriority.BelowNormal };
            thread.Start();
        }

        /// <summary>Following text goes to chunks in <paramref name="dir"/> (the open chunk is finished first).</summary>
        public void StartSession(string dir) => Enqueue(new Job { Op = Op.Session, Path = dir });

        /// <summary>Hand <paramref name="text"/> to the pump thread (it owns it from now on and returns it emptied to
        /// <see cref="TakeBuilder"/>'s pool): O(1) on the caller's thread.</summary>
        public void Write(System.Text.StringBuilder text)
        {
            if (text == null || text.Length == 0) return;
            RawChars += text.Length;
            Enqueue(new Job { Op = Op.Text, Text = text });
        }

        /// <summary>An empty builder (pooled: the steady state allocates nothing).</summary>
        public System.Text.StringBuilder TakeBuilder() =>
            pool.TryTake(out var sb) ? sb : new System.Text.StringBuilder(FlightLog.InitialChars);

        /// <summary>Finish the open chunk (it lands in the outbox).</summary>
        public void Rotate() => Enqueue(new Job { Op = Op.Rotate });

        /// <summary>Write a whole small file atomically (meta.json).</summary>
        public void WriteFile(string path, byte[] bytes) => Enqueue(new Job { Op = Op.File, Path = path, Bytes = bytes });

        /// <summary>Write a small file made on the pump thread from the session's <see cref="Lost"/> as of every text
        /// queued before it (exact: no drain or timeout involved).</summary>
        public void WriteFile(string path, Func<long, byte[]> make) => Enqueue(new Job { Op = Op.File, Path = path, Make = make });

        /// <summary>Delete a directory once every job before this one ran (a session too short to keep); the session
        /// <paramref name="owner"/> is <see cref="Owns"/> until then.</summary>
        public void DeleteDir(string path, string owner = null)
        {
            Own(owner);
            Enqueue(new Job { Op = Op.Delete, Path = path, Owner = owner });
        }

        /// <summary>
        /// End session <paramref name="owner"/>: write its final meta.json, then its done marker, both made from the
        /// session's <see cref="Lost"/> as of every text queued before. The marker is never written before that meta.json
        /// is on disk: a failed write is retried with <see cref="Backoff"/> (and once more when the pump stops).
        /// The pump owns the session until its marker is written.
        /// </summary>
        public void Finish(string owner, string metaPath, Func<long, byte[]> meta, string markerPath, Func<long, byte[]> marker)
        {
            Own(owner);
            Enqueue(new Job { Op = Op.Finish, Owner = owner, Path = metaPath, Make = meta, Path2 = markerPath, Make2 = marker });
        }

        /// <summary>True while queued or retried jobs still own the session's outbox (its final files or deletion).
        /// Thread-safe.</summary>
        public bool Owns(string session)
        {
            if (session == null) return false;
            lock (owned) return owned.ContainsKey(session);
        }

        void Own(string session)
        {
            if (session == null) return;
            lock (owned)
            {
                owned.TryGetValue(session, out var n);
                owned[session] = n + 1;
            }
        }

        void Disown(string session)
        {
            if (session == null) return;
            lock (owned)
            {
                if (!owned.TryGetValue(session, out var n)) return;
                if (n <= 1) owned.Remove(session);
                else owned[session] = n - 1;
            }
        }

        /// <summary>Wait until every queued job ran (pause, quit, tests); false on timeout.</summary>
        public bool Drain(int timeoutMs)
        {
            using (var done = new ManualResetEventSlim(false))
            {
                Enqueue(new Job { Op = Op.Barrier, Done = done });
                return done.Wait(timeoutMs);
            }
        }

        void Enqueue(Job job)
        {
            jobs.Enqueue(job);
            wake.Set();
        }

        void Run()
        {
            while (true)
            {
                while (jobs.TryDequeue(out var job))
                {
                    try { Do(job); }
                    catch (Exception e) { Count(e); } // never kill the thread: later jobs and barriers still run
                    finally
                    {
                        Interlocked.Exchange(ref lost, dropped + (writer?.Lost ?? 0));
                        Release(job.Done);
                    }
                }
                RetryEndings(false);
                if (stopping && jobs.IsEmpty) break;
                wake.WaitOne(1000);
            }
            RotateNow();
            RetryEndings(true); // a last try to write pending final files
        }

        void Do(Job job)
        {
            switch (job.Op)
            {
                case Op.Text:
                    Append(job.Text);
                    job.Text.Length = 0;
                    pool.Add(job.Text);
                    break;
                case Op.Rotate: RotateNow(); break;
                case Op.Session:
                    RotateNow();
                    writer = null;
                    dropped = 0;
                    sessionDir = job.Path;
                    OpenWriter();
                    break;
                case Op.File:
                    Try(() => writeFile(job.Path, job.Make != null ? job.Make(dropped + (writer?.Lost ?? 0)) : job.Bytes));
                    break;
                case Op.Barrier: RetryEndings(false); break; // Done is set by Run
                case Op.Delete:
                    try { Try(() => store.DeleteDir(job.Path)); }
                    finally { Disown(job.Owner); }
                    break;
                case Op.Finish:
                    var ending = new Ending { Owner = job.Owner, MetaPath = job.Path, MarkerPath = job.Path2 };
                    try
                    {
                        var lostNow = dropped + (writer?.Lost ?? 0);
                        ending.Meta = job.Make(lostNow);
                        ending.Marker = job.Make2(lostNow);
                    }
                    catch (Exception)
                    {
                        Disown(job.Owner); // no final files to retry
                        throw;
                    }
                    if (!TryFinish(ending)) endings.Add(ending);
                    break;
            }
        }

        // meta.json first, then the marker: a failed write keeps the ending (and its session owned) for a retry.
        bool TryFinish(Ending e)
        {
            try
            {
                if (e.Meta != null)
                {
                    writeFile(e.MetaPath, e.Meta);
                    e.Meta = null;
                }
                writeFile(e.MarkerPath, e.Marker);
            }
            catch (Exception x)
            {
                Count(x);
                e.Failures++;
                e.NextAt = clock() + Backoff.Delay(e.Failures);
                return false;
            }
            Disown(e.Owner);
            return true;
        }

        void RetryEndings(bool all)
        {
            if (endings.Count == 0) return;
            var now = clock();
            for (var i = 0; i < endings.Count;)
            {
                if ((all || now >= endings[i].NextAt) && TryFinish(endings[i])) endings.RemoveAt(i);
                else i++;
            }
        }

        // A session whose chunks could not be numbered yet: tried again on every handoff until it works.
        void OpenWriter()
        {
            if (writer == null && sessionDir != null)
                Try(() => writer = new ChunkWriter(sessionDir, nextFree(sessionDir), unpublished, openFile, store));
        }

        // A failed write tears the open gzip chunk: it is dropped (only its earlier handoffs' text counts in Lost) and
        // this whole handoff is tried once more from its start in a new chunk, so every chunk starts on a line and holds
        // whole lines only; if that fails too, the whole handoff is dropped (counted in Lost).
        void Append(System.Text.StringBuilder text)
        {
            OpenWriter();
            if (writer == null) { dropped += text.Length; return; }
            for (var attempt = 0; ; attempt++)
            {
                var before = writer.OpenBytes; // the open chunk's earlier handoffs
                try
                {
                    for (var at = 0; at < text.Length;)
                    {
                        var n = Math.Min(BlockChars, text.Length - at);
                        // Append encodes each block independently: keep a UTF-16 pair in the same block.
                        if (at + n < text.Length && char.IsHighSurrogate(text[at + n - 1]) && char.IsLowSurrogate(text[at + n])) n--;
                        text.CopyTo(at, block, 0, n);
                        writer.Append(block, n);
                        at += n;
                    }
                    return;
                }
                catch (Exception e)
                {
                    Count(e);
                    writer.Abandon(writer.OpenBytes - before); // this handoff's part is written again or dropped below
                    if (attempt == 0) continue;
                    dropped += text.Length;
                    return;
                }
            }
        }

        void RotateNow()
        {
            string name = null;
            Try(() => name = writer?.Rotate());
            if (name != null) ChunkWritten?.Invoke(name);
        }

        void Try(Action a)
        {
            try { a(); }
            catch (Exception e) { Count(e); }
        }

        static void Release(ManualResetEventSlim done)
        {
            try { done?.Set(); }
            catch (ObjectDisposedException) { } // its Drain already timed out
        }

        void Count(Exception e)
        {
            Interlocked.Increment(ref Errors);
            LastError = e.Message;
        }

        /// <summary>Finish the open chunk and stop the thread (waits up to two seconds).</summary>
        public void Dispose() => Stop(2000);

        public bool Stop(int timeoutMs)
        {
            stopping = true;
            wake.Set();
            return thread.Join(timeoutMs);
        }
    }
}
