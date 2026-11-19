using System;
using System.IO;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class OutboxBudgetTests
    {
        [TestCase(3500L, true)]
        [TestCase(2048L, false)]
        public void PrunesOldestFirstAndBreaksTimestampTiesBySessionId(long budget, bool keepsSecond)
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path, pendingDiskBudgetBytes: budget);
                var newest = Session(store, "20260101-000001-0000");
                var second = Session(store, "20260101-000000-0002");
                var first = Session(store, "20260101-000000-0001");
                Directory.SetLastWriteTimeUtc(first, new DateTime(2026, 1, 3, 0, 0, 0, DateTimeKind.Utc));
                Directory.SetLastWriteTimeUtc(newest, new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc));

                store.PrunePending();

                Assert.That(Directory.Exists(first), Is.False);
                Assert.That(Directory.Exists(second), Is.EqualTo(keepsSecond));
                Assert.That(Directory.Exists(newest), Is.True);
            }
        }

        [TestCase("active")]
        [TestCase("owned")]
        [TestCase("unknown metadata")]
        [TestCase("unknown metadata temp")]
        [TestCase("known metadata temp")]
        [TestCase("missing metadata")]
        [TestCase("missing marker")]
        [TestCase("journal")]
        [TestCase("chunk temp")]
        public void ProtectedSessionsCountTowardBudgetButAreNeverPruned(string protection)
        {
            using (var tmp = new TempDir())
            {
                const string protectedId = "20260101-000000-0001";
                var store = new FileChunkStore(tmp.Path, pendingDiskBudgetBytes: 2048);
                var keep = Session(store, protectedId);
                var eligible = Session(store, "20260101-000001-0001");
                var meta = Path.Combine(keep, FileChunkStore.MetaFile);
                string activeDir = null;
                Func<string, bool> owns = null;
                switch (protection)
                {
                    case "active": activeDir = keep + Path.DirectorySeparatorChar; break;
                    case "owned": owns = id => id == protectedId; break;
                    case "unknown metadata": File.WriteAllText(meta, "{\"format\":42}"); break;
                    case "unknown metadata temp": File.WriteAllText(meta + ".tmp", "{\"format\":42}"); break;
                    case "known metadata temp": File.Copy(meta, meta + ".tmp"); break;
                    case "missing metadata": File.Delete(meta); break;
                    case "missing marker": File.Delete(Path.Combine(keep, DoneMarker.FileName)); break;
                    case "journal": File.WriteAllText(Path.Combine(keep, "chunk-0002.journal"), "pending"); break;
                    case "chunk temp": File.WriteAllText(Path.Combine(keep, "chunk-0002.jsonl.gz.tmp"), "pending"); break;
                }

                store.PrunePending(activeDir, owns);

                Assert.That(Directory.Exists(keep), Is.True);
                Assert.That(new FileInfo(Path.Combine(keep, FileChunkStore.ChunkName(1))).Length, Is.EqualTo(1024));
                Assert.That(Directory.Exists(eligible), Is.False);
            }
        }

        static string Session(FileChunkStore store, string id)
        {
            store.CreateSession(id);
            var dir = store.SessionOutbox(id);
            var meta = new SessionMeta { Session = id, StartUtc = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc) };
            File.WriteAllText(Path.Combine(dir, FileChunkStore.MetaFile), meta.ToJson(null));
            File.WriteAllText(Path.Combine(dir, DoneMarker.FileName), new DoneMarker { session = id }.ToJson());
            File.WriteAllBytes(Path.Combine(dir, FileChunkStore.ChunkName(1)), new byte[1024]);
            return dir;
        }
    }
}
