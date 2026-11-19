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
        readonly List<(string, string)> unpublished;
        byte[] bytes = new byte[64 * 1024];
        Stream journal;
        string tmp, final;
        long committed;

        public ChunkWriter(string sessionDir, int firstIndex = 1, List<(string, string)> unpublished = null,
            Func<string, Stream> openFile = null, IChunkStore store = null)
        {
            dir = sessionDir;
            NextIndex = firstIndex;
            this.unpublished = unpublished ?? new List<(string, string)>();
            this.openFile = openFile;
            this.store = store ?? FileChunkStore.Default;
        }

        public int NextIndex { get; private set; }
        public long OpenBytes { get; private set; }
        public long WrittenBytes { get; private set; }
        public int Unpublished => unpublished.Count;

        /// <summary>Append a record as one length-prefixed UTF-8 block.</summary>
        public void Append(char[] chars, int count)
        {
            if (count <= 0) return;
            if (count > ChunkJournal.MaxFrameBytes / 3) throw new ArgumentOutOfRangeException(nameof(count));
            if (journal == null)
            {
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
                var path = final + ChunkJournal.Suffix;
                var length = committed;
                Close();
                // A failed flush can still have written a full frame. Roll it back before the pump retries.
                if (length == 0) store.DeleteTemp(path);
                else store.TruncateJournal(path, length);
                throw;
            }
            committed += n + 4;
            OpenBytes += n;
        }

        public string Rotate()
        {
            RetryPending();
            if (journal == null) return null;
            var (temp, targetPath) = (tmp, final);
            Close();
            return Publish(temp, targetPath) ? Path.GetFileName(targetPath) : null;
        }

        internal void RetryPending()
        {
            for (var i = unpublished.Count - 1; i >= 0; i--)
            {
                var (pending, target) = unpublished[i];
                try
                {
                    Publish(pending, target);
                }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { }
            }
        }

        void Close()
        {
            if (committed != 0) unpublished.Add((tmp, final));
            try { journal.Dispose(); }
            catch (IOException) { } // frame boundaries are determined by explicit flushes
            finally
            {
                journal = null;
                OpenBytes = committed = 0;
            }
        }

        bool Publish(string temp, string target)
        {
            var exists = ChunkJournal.Publish(store, temp, target, openFile, out var written);
            WrittenBytes += written;
            store.DeleteTemp(target + ChunkJournal.Suffix);
            unpublished.Remove((temp, target));
            return exists;
        }

        public void Dispose() => Rotate();
    }
}
