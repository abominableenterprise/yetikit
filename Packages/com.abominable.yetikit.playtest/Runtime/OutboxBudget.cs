using System;
using System.IO;

namespace YetiKit.Playtest
{
    internal static class OutboxBudget
    {
        // The owner predicate takes a session ID, like ChunkPump.Owns. Call on the session lifecycle thread.
        internal static void Enforce(FileChunkStore store, long bytes, string activeDir, Func<string, bool> owns)
        {
            if (bytes < 0 || bytes == long.MaxValue) return;
            try
            {
                var root = Path.GetFullPath(store.Outbox);
                if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) return;
                var active = activeDir == null ? null : Path.GetFullPath(activeDir)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var entries = Directory.GetFileSystemEntries(root);
                // An ordinal sort of canonical IDs orders by UTC timestamp, then by the hex suffix.
                Array.Sort(entries, StringComparer.Ordinal);
                long used = 0;
                var sizes = new long[entries.Length];
                for (var i = 0; i < entries.Length; i++)
                {
                    sizes[i] = Measure(entries[i], out _, out _);
                    used += sizes[i];
                }
                for (var i = 0; used > bytes && i < entries.Length; i++)
                {
                    var dir = entries[i];
                    var id = Path.GetFileName(dir);
                    if (!SessionRules.IsId(id) || string.Equals(dir, active, StringComparison.OrdinalIgnoreCase) ||
                        owns?.Invoke(id) == true) continue;
                    Measure(dir, out var linked, out var pending);
                    if (linked) continue;
                    var meta = Path.Combine(dir, FileChunkStore.MetaFile);
                    if (!File.Exists(meta) || !File.Exists(Path.Combine(dir, DoneMarker.FileName)) ||
                        !FileChunkStore.CanRecover(meta) || !FileChunkStore.CanRecover(meta + FileChunkStore.TmpSuffix) ||
                        pending || owns?.Invoke(id) == true) continue;
                    store.DeleteDir(dir);
                    used -= sizes[i];
                }
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                // Best effort: if usage is uncertain (including after a partial delete), stop pruning.
            }
        }

        static long Measure(string path, out bool linked, out bool pending)
        {
            var attributes = File.GetAttributes(path);
            linked = (attributes & FileAttributes.ReparsePoint) != 0;
            pending = path.EndsWith(".journal", StringComparison.OrdinalIgnoreCase) ||
                path.EndsWith(FileChunkStore.TmpSuffix, StringComparison.OrdinalIgnoreCase);
            if (linked) return 0;
            if ((attributes & FileAttributes.Directory) == 0) return new FileInfo(path).Length;
            long bytes = 0;
            foreach (var entry in Directory.EnumerateFileSystemEntries(path))
            {
                bytes += Measure(entry, out var childLinked, out var childPending);
                linked |= childLinked;
                pending |= childPending;
            }
            return bytes;
        }
    }
}
