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
            public Func<LostRecords, byte[]> Make;
            public FileChunkStore Budget;
            public string Path2;            // Finish: the done marker
            public Func<LostRecords, byte[]> Make2;
            public string Owner;            // Finish, Delete: the session id it owns until completion
        }

        /// <summary>A session's pending completion or discard. A null marker path means discard.</summary>
        sealed class Ending
        {
            public string Owner, Dir, MetaPath, MarkerPath;
            public FileChunkStore Budget;
            public byte[] Meta, Marker; // Meta: null once it is on disk
            public int Failures;
            public double NextAt;
        }

        readonly ConcurrentQueue<Job> jobs = new ConcurrentQueue<Job>();
        readonly ConcurrentBag<System.Text.StringBuilder> pool = new ConcurrentBag<System.Text.StringBuilder>();
        char[] block = new char[BlockChars]; // pump thread only
        int pendingBuffers, poolSize = PooledBuilders;
        FileChunkStore budget;
        readonly AutoResetEvent wake = new AutoResetEvent(false);
        readonly Thread thread;
        volatile bool stopping;
        bool startupConfigLogged;
        ChunkWriter writer;
        string sessionDir; // pump thread only: the session a failed writer start is retried for
        LostRecords dropped; // pump thread only
        long lost;
        readonly PendingChunks pending;
        readonly IChunkStore store;
        readonly Func<string, int> nextFree;
        readonly Func<string, System.IO.Stream> openFile;
        readonly Action<string, byte[]> writeFile;
        readonly Action<string, byte[]> writeFinalFile;
        readonly Func<double> clock;
        readonly System.Collections.Generic.List<Ending> endings = new System.Collections.Generic.List<Ending>(); // pump thread only
        readonly System.Collections.Generic.Dictionary<string, int> owned = new System.Collections.Generic.Dictionary<string, int>(); // lock it

        /// <summary>Raised on the pump thread with the session dir and file name of each finished chunk.</summary>
        public event Action<string> ChunkWritten;
        public int Errors;
        public string LastError;
        /// <summary>Uncompressed chars accepted by the worker so far.</summary>
        public long RawChars;
        /// <summary>Uncompressed chars lost to worker IO failures in the current session.</summary>
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
            pending = new PendingChunks(this.store, openFile);
            this.writeFile = writeFile ?? this.store.PublishFile;
            writeFinalFile = writeFile ?? (this.store is FileChunkStore files ? files.PublishFinalFile : this.store.PublishFile);
            this.clock = clock ?? (() => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency);
            this.nextFree = nextFree ?? this.store.NextFree;
            for (var i = 0; i < PooledBuilders; i++) pool.Add(new System.Text.StringBuilder(FlightLog.InitialChars));
            thread = new Thread(Run) { IsBackground = true, Name = "FlightRecorder", Priority = ThreadPriority.BelowNormal };
            thread.Start();
        }

        // Main thread, once per recorder even when it rotates through multiple sessions.
        internal void LogStartupConfig(string line)
        {
            if (startupConfigLogged) return;
            startupConfigLogged = true;
            UnityEngine.Debug.Log(line);
        }

        /// <summary>Following text goes to chunks in <paramref name="dir"/> (the open chunk is finished first).</summary>
        public void StartSession(string dir, FileChunkStore budgetStore = null) =>
            Enqueue(new Job { Op = Op.Session, Path = dir, Budget = budgetStore ?? store as FileChunkStore });

        /// <summary>Hand <paramref name="text"/> to the pump thread (it owns it from now on and returns it emptied to
        /// <see cref="TakeBuilder"/>'s pool): O(1) on the caller's thread.</summary>
        public bool Write(System.Text.StringBuilder text) => Write(text, false);

        internal bool Write(System.Text.StringBuilder text, bool flush)
        {
            if (text == null || text.Length == 0) return true;
            if (text.Length > FlightLog.InitialChars || text.Capacity > FlightLog.InitialChars * 8) return false;
            // Leave one slot for Pause/End to hand off the producer buffer before finalizing.
            if (Interlocked.Increment(ref pendingBuffers) > PooledBuilders + (flush ? 1 : 0))
            {
                Interlocked.Decrement(ref pendingBuffers);
                return false;
            }
            RawChars += text.Length;
            Enqueue(new Job { Op = Op.Text, Text = text });
            return true;
        }

        /// <summary>An empty builder (pooled: the steady state allocates nothing).</summary>
        public System.Text.StringBuilder TakeBuilder()
        {
            if (!pool.TryTake(out var sb)) return new System.Text.StringBuilder(FlightLog.InitialChars);
            Interlocked.Decrement(ref poolSize);
            return sb;
        }

        void ReturnBuilder(System.Text.StringBuilder sb)
        {
            sb.Clear();
            if (sb.Capacity > FlightLog.InitialChars) return;
            if (Interlocked.Increment(ref poolSize) <= PooledBuilders) pool.Add(sb);
            else Interlocked.Decrement(ref poolSize);
        }

        /// <summary>Finish the open chunk (it lands in the outbox).</summary>
        public void Rotate() => Enqueue(new Job { Op = Op.Rotate });

        /// <summary>Write a whole small file atomically (meta.json).</summary>
        public void WriteFile(string path, byte[] bytes) => Enqueue(new Job { Op = Op.File, Path = path, Bytes = bytes });

        /// <summary>Write a small file made on the pump thread from the session's <see cref="Lost"/> as of every text
        /// queued before it (exact: no drain or timeout involved).</summary>
        public void WriteFile(string path, Func<LostRecords, byte[]> make) => Enqueue(new Job { Op = Op.File, Path = path, Make = make });

        /// <summary>Delete a directory once every job before this one ran (a session too short to keep); the session
        /// <paramref name="owner"/> stays owned until deletion succeeds.</summary>
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
        public void Finish(string owner, string metaPath, Func<LostRecords, byte[]> meta, string markerPath, Func<LostRecords, byte[]> marker)
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
                        Interlocked.Exchange(ref lost, dropped.Chars);
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
                    try { Append(job.Text); }
                    finally
                    {
                        ReturnBuilder(job.Text);
                        Interlocked.Decrement(ref pendingBuffers);
                    }
                    break;
                case Op.Rotate: RotateNow(); break;
                case Op.Session:
                    RotateNow();
                    writer = null;
                    dropped = default;
                    sessionDir = job.Path;
                    budget = job.Budget;
                    budget?.PrunePending(sessionDir, Owns);
                    OpenWriter();
                    break;
                case Op.File:
                    Try(() => writeFile(job.Path, job.Make != null ? job.Make(dropped) : job.Bytes));
                    break;
                case Op.Barrier: RetryEndings(false); break; // Done is set by Run
                case Op.Delete:
                    EndOrRetry(new Ending { Owner = job.Owner, Dir = job.Path });
                    break;
                case Op.Finish:
                    var ending = new Ending { Owner = job.Owner, Dir = sessionDir, MetaPath = job.Path, MarkerPath = job.Path2, Budget = budget };
                    try
                    {
                        var lostNow = dropped;
                        ending.Meta = job.Make(lostNow);
                        ending.Marker = job.Make2(lostNow);
                    }
                    catch (Exception)
                    {
                        Disown(job.Owner); // no final files to retry
                        throw;
                    }
                    EndOrRetry(ending);
                    break;
            }
        }

        void EndOrRetry(Ending ending)
        {
            if (!TryEnd(ending)) endings.Add(ending);
        }

        bool TryEnd(Ending e)
        {
            try
            {
                if (e.MarkerPath == null)
                {
                    store.DeleteDir(e.Dir);
                    pending.Forget(e.Dir);
                }
                else FinishFiles(e);
            }
            catch (Exception x)
            {
                Count(x);
                e.Failures++;
                e.NextAt = clock() + Backoff.Delay(e.Failures);
                return false;
            }
            Disown(e.Owner);
            e.Budget?.PrunePending(sessionDir == null || System.IO.Path.GetFileName(sessionDir) == e.Owner ? null : sessionDir, Owns);
            return true;
        }

        void FinishFiles(Ending e)
        {
            pending.Retry();
            if (pending.Contains(e.Dir))
                throw new System.IO.IOException("Session chunks are still pending publication.");
            // Persist metadata and the chunk renames before the marker can become visible.
            if (e.Meta != null)
            {
                writeFinalFile(e.MetaPath, e.Meta);
                e.Meta = null;
            }
            writeFinalFile(e.MarkerPath, e.Marker);
        }

        void RetryEndings(bool all)
        {
            if (endings.Count == 0) return;
            var now = clock();
            for (var i = 0; i < endings.Count;)
            {
                if ((all || now >= endings[i].NextAt) && TryEnd(endings[i])) endings.RemoveAt(i);
                else i++;
            }
        }

        // A session whose chunks could not be numbered yet: tried again on every handoff until it works.
        void OpenWriter()
        {
            if (writer == null && sessionDir != null)
                Try(() => writer = new ChunkWriter(sessionDir, nextFree(sessionDir), openFile, store, pending));
        }

        void Append(System.Text.StringBuilder text)
        {
            OpenWriter();
            for (int start = 0, end = 0; end < text.Length; end++)
            {
                if (text[end] != '\n' && end + 1 != text.Length) continue;
                var n = end - start + 1;
                if (block.Length < n) block = new char[n];
                text.CopyTo(start, block, 0, n);
                var kept = false;
                for (var attempt = 0; writer != null && attempt < 2; attempt++)
                {
                    try { writer.Append(block, n); kept = true; break; }
                    catch (Exception e) { Count(e); }
                }
                if (!kept) dropped.Add(LostRecords.TimeOf(text.ToString(start, n)), n);
                start = end + 1;
            }
        }

        void RotateNow()
        {
            string name = null;
            if (writer == null) Try(() => pending.Retry());
            else Try(() => name = writer.Rotate());
            if (name != null) ChunkWritten?.Invoke(name);
            budget?.PrunePending(sessionDir, Owns);
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
