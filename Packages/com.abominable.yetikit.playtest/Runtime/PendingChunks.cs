using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;

namespace YetiKit.Playtest
{
    // A pump owns this queue across session switches, even when no writer can be opened.
    internal sealed class PendingChunks
    {
        // Preserve in-process rollback even if writing the checkpoint fails. The weak key
        // keeps the state alive only as long as the caller's actual queue instance.
        static readonly ConditionalWeakTable<List<(string, string)>, Dictionary<string, (string dir, long length)>> SharedRollbacks =
            new ConditionalWeakTable<List<(string, string)>, Dictionary<string, (string dir, long length)>>();

        readonly IChunkStore store;
        readonly Func<string, Stream> openFile;
        readonly List<(string temp, string final)> chunks;
        readonly Dictionary<string, (string dir, long length)> rollback;

        internal PendingChunks(IChunkStore store, Func<string, Stream> openFile, List<(string, string)> chunks = null)
        {
            this.store = store;
            this.openFile = openFile;
            this.chunks = chunks ?? new List<(string, string)>();
            rollback = chunks == null ? new Dictionary<string, (string dir, long length)>() : SharedRollbacks.GetOrCreateValue(chunks);
        }

        internal int Count => chunks.Count;
        internal bool Contains(string dir) => chunks.Exists(chunk => Path.GetDirectoryName(chunk.final) == dir);

        internal void Forget(string dir)
        {
            chunks.RemoveAll(chunk =>
            {
                if (Path.GetDirectoryName(chunk.final) != dir) return false;
                rollback.Remove(chunk.final);
                return true;
            });
        }

        internal void Add(string temp, string final, string dir, long? boundary)
        {
            chunks.Add((temp, final));
            if (boundary.HasValue) rollback.Add(final, (dir, boundary.Value));
        }

        internal void RollBackIn(string dir)
        {
            if (rollback.Count == 0) return;
            foreach (var (_, final) in chunks)
                if (rollback.TryGetValue(final, out var work) && work.dir == dir) RollBack(final);
        }

        internal void RollBack(string final)
        {
            if (!rollback.TryGetValue(final, out var work)) return;
            var path = final + ChunkJournal.Suffix;
            try { JournalRollback.Apply(store, path, work.length); }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                // Best effort under a storage fault. Keep retrying in memory if even the marker cannot be written.
                JournalRollback.Remember(store, path, work.length);
                throw;
            }
            rollback.Remove(final);
        }

        internal bool Publish(string temp, string final, out long written)
        {
            RollBack(final);
            var exists = ChunkJournal.Publish(store, temp, final, openFile, out written);
            store.DeleteTemp(final + ChunkJournal.Suffix);
            chunks.Remove((temp, final));
            return exists;
        }

        internal long Retry()
        {
            long total = 0;
            for (var i = chunks.Count - 1; i >= 0; i--)
            {
                var (temp, final) = chunks[i];
                try
                {
                    Publish(temp, final, out var written);
                    total += written;
                }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { }
            }
            return total;
        }
    }
}
