using System.IO;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class FormatRecoveryTests
    {
        [Test]
        public void RecoveryDiscardsTornTempBesideCommittedMetadataAndRecoversJournal()
        {
            using (var tmp = new TempDir())
            {
                const string id = "20260101-000000-0001";
                const string line = "{\"t\":0,\"k\":\"test\"}\n";
                var store = new FileChunkStore(tmp.Path);
                store.CreateSession(id);
                var dir = store.SessionOutbox(id);
                var meta = Path.Combine(dir, FileChunkStore.MetaFile);
                var metadata = new SessionMeta(id).ToJson(null);
                File.WriteAllText(meta, metadata);
                File.WriteAllText(meta + ".tmp", "{\"format\":1,\"session\":\"");
                var final = Path.Combine(dir, FileChunkStore.ChunkName(1));
                var journal = final + ChunkJournal.Suffix;
                using (var file = new BinaryWriter(File.Create(journal)))
                {
                    var bytes = System.Text.Encoding.UTF8.GetBytes(line);
                    file.Write(bytes.Length);
                    file.Write(bytes);
                    file.Write((byte)20); // torn frame header
                }

                store.RecoverChunks();
                store.RecoverChunks();

                Assert.IsTrue(File.Exists(final), "a torn metadata temp must not block recovery");
                Assert.AreEqual(line, TempDir.Gunzip(final));
                Assert.IsFalse(File.Exists(journal));
                Assert.IsFalse(File.Exists(meta + ".tmp"));
                var recovered = File.ReadAllText(meta);
                StringAssert.Contains("\"session\":\"" + id + "\"", recovered);
                StringAssert.Contains("\"torn\":1", recovered);
            }
        }

        [TestCase("meta.json", false, "{\"format\":42}")]
        [TestCase("meta.json.tmp", false, "{\"format\":42}")]
        [TestCase("meta.json.tmp", true, "{\"format\":42}")]
        [TestCase("meta.json.tmp", true, "{\"format\":42,\"session\":\"")]
        [TestCase("meta.json.tmp", false, "{\"format\":1,\"session\":\"")]
        public void RecoveryLeavesUnsupportedOrUnconfirmedMetadataIntact(string metadataName, bool committed, string contents)
        {
            using (var tmp = new TempDir())
            {
                const string id = "20260101-000000-0001";
                var store = new FileChunkStore(tmp.Path);
                var dir = store.SessionOutbox(id);
                Directory.CreateDirectory(dir);
                var meta = Path.Combine(dir, metadataName);
                if (committed) File.WriteAllText(Path.Combine(dir, FileChunkStore.MetaFile), new SessionMeta(id).ToJson(null));
                File.WriteAllText(meta, contents);
                var done = Path.Combine(dir, "session.done");
                File.WriteAllText(done, "{\"session\":\"" + id + "\"}");
                var final = Path.Combine(dir, "chunk-0001.jsonl.gz");
                using (var writer = new ChunkWriter(dir))
                {
                    var line = "{\"t\":0,\"k\":\"test\"}\n".ToCharArray();
                    writer.Append(line, line.Length);
                }
                var pending = final + ".tmp";
                File.Move(final, pending);
                var torn = Path.Combine(dir, "chunk-0002.jsonl.gz.tmp");
                File.WriteAllText(torn, "incomplete");
                var original = Directory.GetFiles(dir);
                var bytes = System.Array.ConvertAll(original, File.ReadAllBytes);

                store.RecoverChunks();

                CollectionAssert.AreEquivalent(original, Directory.GetFiles(dir));
                for (var i = 0; i < original.Length; i++)
                    CollectionAssert.AreEqual(bytes[i], File.ReadAllBytes(original[i]), Path.GetFileName(original[i]));
            }
        }
    }
}
