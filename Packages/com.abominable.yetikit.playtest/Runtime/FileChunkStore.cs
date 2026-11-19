using System;
using System.IO;
using System.IO.Compression;
using System.Runtime.Serialization.Json;
using System.Xml;

namespace YetiKit.Playtest
{
    /// <summary>Local recordings in <c>&lt;root&gt;/outbox/&lt;session&gt;/</c> (meta.json and gzip chunks).</summary>
    public sealed class FileChunkStore : IChunkStore
    {
        public const string Folder = "playtest", OutboxFolder = "outbox";
        public const string MetaFile = "meta.json", ChunkPrefix = "chunk-", ChunkSuffix = ".jsonl.gz", TmpSuffix = ".tmp";

        static readonly object SessionCreation = new object();
        internal static readonly FileChunkStore Default = new FileChunkStore(string.Empty);
        public readonly string Outbox;

        readonly long pendingDiskBudgetBytes;

        public FileChunkStore(string root, long pendingDiskBudgetBytes = long.MaxValue)
        {
            Outbox = Path.Combine(root, OutboxFolder);
            this.pendingDiskBudgetBytes = pendingDiskBudgetBytes;
        }

        /// <summary>Best-effort pruning of completed sessions to the configured budget.</summary>
        public void PrunePending(string activeDir = null, Func<string, bool> owns = null) =>
            OutboxBudget.Enforce(this, pendingDiskBudgetBytes, activeDir, owns);

        public string SessionOutbox(string session)
        {
            if (!SessionRules.IsId(session)) throw new ArgumentException("Invalid session ID.", nameof(session));
            return Path.Combine(Outbox, session);
        }

        public void CreateSession(string session)
        {
            var dir = SessionOutbox(session);
            lock (SessionCreation)
            {
                if (Directory.Exists(dir)) throw new IOException("The session directory already exists.");
                Directory.CreateDirectory(dir);
            }
        }

        /// <summary><c>chunk-0001.jsonl.gz</c> (1-based, zero-padded to 4).</summary>
        public static string ChunkName(int index) => ChunkPrefix + index.ToString("D4") + ChunkSuffix;

        /// <summary>The chunk number of a chunk file name, or -1.</summary>
        public static int ChunkIndex(string name)
        {
            if (name == null || !name.StartsWith(ChunkPrefix, StringComparison.Ordinal) ||
                !name.EndsWith(ChunkSuffix, StringComparison.Ordinal)) return -1;
            var digits = name.Substring(ChunkPrefix.Length, name.Length - ChunkPrefix.Length - ChunkSuffix.Length);
            return digits.Length >= 4 && int.TryParse(digits, out var n) && n > 0 ? n : -1;
        }

        public int NextFree(string dir)
        {
            var next = 1;
            if (Directory.Exists(dir))
                foreach (var f in Directory.GetFiles(dir))
                {
                    var name = Path.GetFileName(f);
                    var suffix = name.EndsWith(ChunkJournal.Suffix, StringComparison.Ordinal) ? ChunkJournal.Suffix : TmpSuffix;
                    var n = ChunkIndex(name.EndsWith(suffix, StringComparison.Ordinal)
                        ? name.Substring(0, name.Length - suffix.Length) : name);
                    if (n >= next) next = n + 1;
                }
            return next;
        }

        public (string temp, string final) ChunkPaths(string dir, int index)
        {
            var final = Path.Combine(dir, ChunkName(index));
            return (final + TmpSuffix, final);
        }

        public Stream OpenTemp(string path, Func<string, Stream> openFile)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            return openFile != null ? openFile(path) : new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 64 * 1024);
        }

        public bool TempExists(string path) => File.Exists(path);
        public long TempLength(string path) => new FileInfo(path).Length;
        public void DeleteTemp(string path) => File.Delete(path);

        public void TruncateJournal(string path, long length)
        {
            using (var file = File.OpenWrite(path)) file.SetLength(length);
        }

        public void PublishChunk(string temp, string final) => File.Move(temp, final);

        public void PublishFile(string path, byte[] bytes) => WriteAtomic(path, bytes);

        public void DeleteDir(string dir)
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }

        /// <summary>Write a small file via a temporary file. On a failed rename, keep a complete temp if the target is gone.</summary>
        public static void WriteAtomic(string path, byte[] bytes)
        {
            var tmp = path + TmpSuffix;
            try
            {
                File.WriteAllBytes(tmp, bytes);
                for (var i = 1; ; i++)
                {
                    try
                    {
                        if (File.Exists(path)) File.Replace(tmp, path, null);
                        else File.Move(tmp, path);
                        return;
                    }
                    catch (IOException) when (i < 20) { System.Threading.Thread.Sleep(50); }
                }
            }
            catch (Exception)
            {
                try { if (File.Exists(path) || !File.Exists(tmp) || new FileInfo(tmp).Length != bytes.Length) File.Delete(tmp); }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { }
                throw;
            }
        }

        /// <summary>At startup, publish whole gzip temps and remove torn or redundant gzip temps, even in finished sessions.</summary>
        public void RecoverChunks()
        {
            if (!Directory.Exists(Outbox)) return;
            foreach (var dir in Directory.GetDirectories(Outbox))
            {
                if (!SessionRules.IsId(Path.GetFileName(dir)) ||
                    !CanRecover(Path.Combine(dir, MetaFile)) || !CanRecover(Path.Combine(dir, MetaFile + TmpSuffix))) continue;
                var journals = Directory.GetFiles(dir, "*" + ChunkJournal.Suffix);
                Array.Sort(journals, (a, b) => JournalIndex(a).CompareTo(JournalIndex(b)));
                foreach (var journal in journals)
                {
                    var index = JournalIndex(journal);
                    if (index < 0) continue;
                    var final = journal.Substring(0, journal.Length - ChunkJournal.Suffix.Length);
                    ChunkJournal.Publish(this, final + TmpSuffix, final, null, out _);
                    if (ChunkJournal.HasTornTail(journal)) RecoveryLoss.Record(this, dir, index);
                    DeleteTemp(journal);
                }
                foreach (var temp in Directory.GetFiles(dir))
                {
                    if (!temp.EndsWith(TmpSuffix, StringComparison.Ordinal)) continue;
                    var final = temp.Substring(0, temp.Length - TmpSuffix.Length);
                    if (ChunkIndex(Path.GetFileName(final)) < 0) continue;
                    if (!File.Exists(final) && WholeGzip(temp)) PublishChunk(temp, final);
                    else DeleteTemp(temp);
                }
            }
        }

        static int JournalIndex(string path) => ChunkIndex(Path.GetFileName(path).Substring(0,
            Path.GetFileName(path).Length - ChunkJournal.Suffix.Length));

        // Older recordings have no format. Unreadable or explicitly unknown metadata is left untouched.
        internal static bool CanRecover(string path)
        {
            try
            {
                using (var file = File.OpenRead(path))
                using (var json = JsonReaderWriterFactory.CreateJsonReader(file, XmlDictionaryReaderQuotas.Max))
                {
                    if (json.MoveToContent() != XmlNodeType.Element || json.GetAttribute("type") != "object") return false;
                    var seen = false;
                    json.ReadStartElement();
                    while (json.MoveToContent() == XmlNodeType.Element)
                    {
                        if (json.LocalName != "format") { json.Skip(); continue; }
                        if (seen || json.GetAttribute("type") != "number" ||
                            json.ReadElementContentAsString() != SessionMeta.Format.ToString(System.Globalization.CultureInfo.InvariantCulture)) return false;
                        seen = true;
                    }
                    json.ReadEndElement();
                    return json.MoveToContent() == XmlNodeType.None;
                }
            }
            catch (FileNotFoundException) { return true; }
            catch (Exception e) when (e is XmlException || e is IOException || e is UnauthorizedAccessException) { return false; }
        }

        /// <summary>A finished gzip: it inflates and its trailer's size matches.</summary>
        static bool WholeGzip(string path)
        {
            try
            {
                using (var file = File.OpenRead(path))
                {
                    if (file.Length < 18) return false;
                    file.Seek(-4, SeekOrigin.End);
                    uint size = 0;
                    for (var i = 0; i < 4; i++) size |= (uint)file.ReadByte() << (8 * i);
                    file.Position = 0;
                    long total = 0;
                    using (var g = new GZipStream(file, CompressionMode.Decompress))
                    {
                        var buf = new byte[16 * 1024];
                        for (int n; (n = g.Read(buf, 0, buf.Length)) > 0;) total += n;
                    }
                    return total > 0 && (uint)total == size;
                }
            }
            catch (InvalidDataException) { return false; }
            // Unity's Mono inflater signals corrupt data with a plain IOException. Do not discard a temp
            // on other IO failures: the recording might still be intact.
            catch (IOException e) when (e.Message.StartsWith("Corrupted data ", StringComparison.Ordinal)) { return false; }
        }
    }
}
