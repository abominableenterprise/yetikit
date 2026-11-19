using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace YetiKit.Playtest
{
    // Persist only exceptional rollback work, not a second checkpoint for every record.
    internal static class JournalRollback
    {
        internal const string Suffix = ".rollback";

        internal static void Remember(IChunkStore store, string journal, long boundary)
        {
            var path = journal + Suffix;
            if (store.TempExists(path)) return;
            var bytes = Encoding.UTF8.GetBytes(boundary.ToString(CultureInfo.InvariantCulture));
            if (store is FileChunkStore disk) disk.PublishFinalFile(path, bytes);
            else store.PublishFile(path, bytes);
        }

        internal static void Apply(IChunkStore store, string journal, long boundary)
        {
            if (boundary == 0) store.DeleteTemp(journal);
            else store.TruncateJournal(journal, boundary);
            var marker = journal + Suffix;
            // A failed checkpoint rename can leave a temp. Remove it before the final marker
            // so an interrupted cleanup does not leave an orphan that blocks startup recovery.
            store.DeleteTemp(marker + FileChunkStore.TmpSuffix);
            store.DeleteTemp(marker);
        }

        internal static bool Recover(FileChunkStore store, string marker)
        {
            var journal = marker.Substring(0, marker.Length - Suffix.Length);
            if (!long.TryParse(File.ReadAllText(marker), NumberStyles.None, CultureInfo.InvariantCulture, out var boundary))
                return false;
            if (boundary != 0 && (!File.Exists(journal) || new FileInfo(journal).Length < boundary)) return false;
            Apply(store, journal, boundary);
            return true;
        }
    }
}
