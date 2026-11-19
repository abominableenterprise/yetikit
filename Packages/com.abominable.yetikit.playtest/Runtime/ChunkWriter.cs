using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace YetiKit.Playtest
{
    /// <summary>One worker's in-flight journal and finalized gzip chunks.</summary>
    public sealed class ChunkWriter : IDisposable
    {
        readonly string dir;
        readonly IChunkStore store;
        readonly Func<string, Stream> openFile;
        readonly PendingChunks pending;
        byte[] bytes = new byte[64 * 1024];
        Stream journal;
        string tmp, final, failedJournal;
        long committed;

        public ChunkWriter(string sessionDir, int firstIndex = 1, List<(string, string)> unpublished = null,
            Func<string, Stream> openFile = null, IChunkStore store = null)
            : this(sessionDir, firstIndex, openFile, store ?? FileChunkStore.Default,
                new PendingChunks(store ?? FileChunkStore.Default, openFile, unpublished)) { }

        internal ChunkWriter(string sessionDir, int firstIndex, Func<string, Stream> openFile, IChunkStore store, PendingChunks pending)
        {
            dir = sessionDir;
            NextIndex = firstIndex;
            this.pending = pending;
            this.openFile = openFile;
            this.store = store;
        }

        public int NextIndex { get; private set; }
        public long OpenBytes { get; private set; }
        public long WrittenBytes { get; private set; }
        public int Unpublished => pending.Count;

        /// <summary>Append a record as one length-prefixed UTF-8 block.</summary>
        public void Append(char[] chars, int count)
        {
            if (count <= 0) return;
            if (count > ChunkJournal.MaxFrameBytes / 3) throw new ArgumentOutOfRangeException(nameof(count));
            if (journal == null)
            {
                // Do not write a retry copy while the failed frame might still be recoverable.
                if (failedJournal != null)
                {
                    pending.RollBack(failedJournal);
                    failedJournal = null;
                }
                var paths = store.ChunkPaths(dir, NextIndex++);
                journal = store.OpenTemp(paths.final + ChunkJournal.Suffix, openFile);
                (tmp, final) = paths;
            }
            var max = Encoding.UTF8.GetMaxByteCount(count) + 4;
            if (bytes.Length < max) bytes = new byte[max];
            var n = Encoding.UTF8.GetBytes(chars, 0, count, bytes, 4);
            for (var i = 0; i < 4; i++) bytes[i] = (byte)(n >> (i * 8));
            try
            {
                journal.Write(bytes, 0, n + 4);
                journal.Flush(); // visible to the next process before this record is acknowledged
            }
            catch
            {
                // A failed flush can still have written a full frame. Keep its rollback boundary
                // in the pump's queue before closing, including when it was the first frame.
                failedJournal = final;
                Close(committed);
                pending.RollBack(failedJournal);
                failedJournal = null;
                throw;
            }
            committed += n + 4;
            OpenBytes += n;
        }

        public string Rotate()
        {
            WrittenBytes += pending.Retry();
            if (journal == null) return null;
            var (temp, targetPath) = (tmp, final);
            Close();
            var published = pending.Publish(temp, targetPath, out var written);
            WrittenBytes += written;
            return published ? Path.GetFileName(targetPath) : null;
        }

        void Close(long? boundary = null)
        {
            if (committed != 0 || boundary.HasValue) pending.Add(tmp, final, boundary);
            try { journal.Dispose(); }
            catch (IOException) { } // frame boundaries are determined by explicit flushes
            finally
            {
                journal = null;
                OpenBytes = committed = 0;
            }
        }

        public void Dispose() => Rotate();
    }
}
