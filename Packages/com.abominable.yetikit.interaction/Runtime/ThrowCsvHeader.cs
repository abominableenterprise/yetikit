using System;
using System.IO;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Archives a CSV with an outdated header before new rows are written. The archive is timestamped
    /// and stored beside the original file.
    /// </summary>
    public static class ThrowCsvHeader
    {
        public const string StampFormat = "yyyyMMdd-HHmmss";

        /// <summary>
        /// When <paramref name="file"/> exists and its first line is not <paramref name="header"/>, rename it to
        /// <see cref="ArchivePath"/> (stamped <paramref name="now"/>) and return that path; else null (no file, an empty
        /// one or the current header: appending is fine).
        /// </summary>
        public static string Rotate(string file, string header, DateTime now)
        {
            if (!File.Exists(file)) return null;
            string first;
            using (var reader = new StreamReader(file)) first = reader.ReadLine();
            if (first == null || first == header) return null;
            var archive = ArchivePath(file, now);
            for (var n = 1; File.Exists(archive); n++) archive = ArchivePath(file, now, n);
            File.Move(file, archive);
            return archive;
        }

        /// <summary>Builds the timestamped archive path beside <paramref name="file"/>, with an optional numeric suffix.</summary>
        public static string ArchivePath(string file, DateTime now, int n = 0)
        {
            var dir = Path.GetDirectoryName(file) ?? "";
            var name = $"{Path.GetFileNameWithoutExtension(file)}-{now.ToString(StampFormat)}{(n > 0 ? $"-{n}" : "")}{Path.GetExtension(file)}";
            return Path.Combine(dir, name);
        }
    }
}
