using System.IO;
using System.IO.Compression;
using System.Text;

namespace YetiKit.Playtest
{
    /// <summary>
    /// One session's gzip'd JSON Lines chunks (plain class; <see cref="ChunkPump"/> runs it on its background thread).
    /// Text streams straight into <c>chunk-NNNN.jsonl.gz.tmp</c>; <see cref="Rotate"/> finishes the gzip and renames it
    /// to <c>chunk-NNNN.jsonl.gz</c>, so the outbox only ever holds whole chunks. Not thread-safe: one thread uses it.
    /// </summary>
    public sealed class ChunkWriter : System.IDisposable
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        readonly string dir;
        readonly IChunkStore store;
        byte[] bytes = new byte[64 * 1024];
        WriteGuardStream file;
        readonly System.Func<string, Stream> openFile;
        GZipStream gzip;
        string tmpPath, finalPath;
        readonly System.Collections.Generic.List<(string tmp, string final)> unpublished;

        /// <param name="unpublished">Chunks whose rename failed, shared by the pump's writers so a new session's writer
        /// keeps retrying the last session's (null: this writer's own list).</param>
        /// <param name="openFile">Creates a chunk's .tmp file (tests inject a failing disk).</param>
        public ChunkWriter(string sessionDir, int firstIndex = 1, System.Collections.Generic.List<(string, string)> unpublished = null,
            System.Func<string, Stream> openFile = null, IChunkStore store = null)
        {
            this.openFile = openFile;
            this.store = store ?? FileChunkStore.Default;
            dir = sessionDir;
            NextIndex = firstIndex;
            this.unpublished = unpublished ?? new System.Collections.Generic.List<(string, string)>();
        }

        /// <summary>The number the next chunk gets.</summary>
        public int NextIndex { get; private set; }
        /// <summary>Uncompressed bytes in the open chunk.</summary>
        public long OpenBytes { get; private set; }
        /// <summary>Uncompressed bytes dropped with a chunk that could not be written whole (<see cref="Abandon"/>).</summary>
        public long Lost { get; private set; }
        /// <summary>Compressed bytes of every finished chunk.</summary>
        public long WrittenBytes { get; private set; }

        /// <summary>Add text to the open chunk (opened on first use).</summary>
        public void Append(char[] chars, int count)
        {
            if (count <= 0) return;
            if (gzip == null) Open();
            var max = Utf8.GetMaxByteCount(count);
            if (bytes.Length < max) bytes = new byte[max];
            var n = Utf8.GetBytes(chars, 0, count, bytes, 0);
            gzip.Write(bytes, 0, n);
            OpenBytes += n;
        }

        /// <summary>
        /// Finish the open chunk and publish it; returns its file name, or null when nothing was written. Throws on an
        /// IO error, but the file is closed either way: a chunk whose gzip could not be finished is deleted; a whole chunk
        /// whose rename failed stays a .tmp, retried on every later rotation and
        /// published by startup recovery.
        /// </summary>
        public string Rotate()
        {
            RetryUnpublished();
            if (gzip == null) return null;
            var tmp = tmpPath;
            var final = finalPath;
            var open = OpenBytes;
            tmpPath = finalPath = null;
            OpenBytes = 0;
            try
            {
                gzip.Dispose(); // writes the gzip trailer
                if (file.Failure != null) throw file.Failure; // swallowed by the gzip dispose: the chunk is torn
                file.Flush();
            }
            catch (System.Exception)
            {
                Lost += open;
                // A torn gzip cannot be read back whole: drop it (counted by the pump).
                Close();
                DropTemp(tmp);
                throw;
            }
            Close();
            try
            {
                WrittenBytes += store.TempLength(tmp);
                store.PublishChunk(tmp, final);
            }
            catch (System.Exception)
            {
                unpublished.Add((tmp, final)); // complete: published by the next rotation or startup recovery
                throw;
            }
            return Path.GetFileName(final);
        }

        /// <summary>A write failed: the open chunk's gzip stream is torn, so drop it (its bytes count as
        /// <see cref="Lost"/>); the next <see cref="Append"/> opens the next chunk number.</summary>
        /// <param name="retried">Bytes at the end of the chunk the caller writes again (or counts itself): not lost here.</param>
        public void Abandon(long retried = 0)
        {
            Lost += System.Math.Max(0, OpenBytes - retried);
            OpenBytes = 0;
            var tmp = tmpPath;
            tmpPath = finalPath = null;
            try { gzip?.Dispose(); } catch (System.Exception) { }
            Close();
            if (tmp != null) DropTemp(tmp);
        }

        void DropTemp(string tmp)
        {
            try { store.DeleteTemp(tmp); }
            catch (System.Exception e) when (e is IOException || e is System.UnauthorizedAccessException) { }
        }

        void Close()
        {
            gzip = null;
            try { file?.Dispose(); } catch (IOException) { }
            file = null;
        }

        /// <summary>Chunks whose rename failed, still waiting as a .tmp.</summary>
        public int Unpublished => unpublished.Count;

        void RetryUnpublished()
        {
            for (var i = unpublished.Count - 1; i >= 0; i--)
            {
                var (tmp, final) = unpublished[i];
                try
                {
                    if (store.TempExists(tmp)) store.PublishChunk(tmp, final);
                    unpublished.RemoveAt(i);
                }
                catch (System.Exception e) when (e is IOException || e is System.UnauthorizedAccessException) { }
            }
        }

        void Open()
        {
            var (temp, final) = store.ChunkPaths(dir, NextIndex++);
            file = new WriteGuardStream(store.OpenTemp(temp, openFile));
            tmpPath = temp;
            finalPath = final;
            gzip = new GZipStream(file, CompressionLevel.Optimal, true);
        }

        /// <summary>Publish what is open.</summary>
        public void Dispose() => Rotate();
    }
}
