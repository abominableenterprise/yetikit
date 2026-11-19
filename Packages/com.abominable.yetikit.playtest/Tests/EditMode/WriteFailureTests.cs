using System.IO;
using System.Text;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    /// <summary>Disk faults never kill the pump thread or lose a whole chunk on rename.</summary>
    public class WriteFailureTests
    {
        const string S1 = "20261029-070000-0001";

        [Test]
        public void ASessionThatCannotStartDoesNotKillThePumpAndRetriesOnTheNextWrite()
        {
            using (var tmp = new TempDir())
            {
                var fail = true;
                var store = new FileChunkStore(tmp.Path);
                using (var pump = new ChunkPump(dir =>
                {
                    if (fail) { fail = false; throw new IOException("disk gone"); }
                    return store.NextFree(dir);
                }, store: store))
                {
                    var a = Path.Combine(tmp.Path, "a");
                    pump.StartSession(a);
                    Assert.IsTrue(pump.Drain(5000), "barriers still complete after the failure");
                    Assert.AreEqual(1, pump.Errors);
                    Assert.AreEqual("disk gone", pump.LastError);
                    pump.Write(new StringBuilder("{\"k\":\"kept\"}\n"));
                    pump.Rotate();
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual("{\"k\":\"kept\"}\n", TempDir.Gunzip(Path.Combine(a, "chunk-0001.jsonl.gz")), "the writer is retried");
                    Assert.AreEqual(0, pump.Lost);
                }
            }
        }

        [Test]
        public void AChunkStuckAtTheEndOfASessionIsStillPublishedAfterTheNextOneStarts()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var a = Path.Combine(tmp.Path, "a");
                var b = Path.Combine(tmp.Path, "b");
                var stuck = Path.Combine(a, "chunk-0001.jsonl.gz");
                Directory.CreateDirectory(stuck); // the rename target is blocked
                pump.StartSession(a);
                pump.Write(new StringBuilder("{\"k\":\"a\"}\n"));
                pump.StartSession(b); // finishes a's chunk: its rename fails
                Assert.IsTrue(pump.Drain(5000));
                Assert.IsTrue(File.Exists(stuck + ".tmp"));
                Directory.Delete(stuck);
                pump.Write(new StringBuilder("{\"k\":\"b\"}\n"));
                pump.Rotate();
                Assert.IsTrue(pump.Drain(5000));
                Assert.AreEqual("{\"k\":\"a\"}\n", TempDir.Gunzip(stuck), "retried by b's writer");
                Assert.IsFalse(File.Exists(stuck + ".tmp"));
                Assert.AreEqual("{\"k\":\"b\"}\n", TempDir.Gunzip(Path.Combine(b, "chunk-0001.jsonl.gz")));
            }
        }

        [Test]
        public void AFailedRenameKeepsTheWholeChunkAndRetriesIt()
        {
            using (var tmp = new TempDir())
            {
                var w = new ChunkWriter(tmp.Path);
                var final = Path.Combine(tmp.Path, "chunk-0001.jsonl.gz");
                Directory.CreateDirectory(final); // the rename target is blocked
                var a = "{\"t\":0,\"k\":\"start\"}\n".ToCharArray();
                w.Append(a, a.Length);
                Assert.Catch<System.Exception>(() => w.Rotate());
                Assert.AreEqual(1, w.Unpublished);
                Assert.AreEqual(new string(a), TempDir.Gunzip(final + ".tmp"), "the .tmp is the closed, whole chunk");
                Directory.Delete(final);
                Assert.IsNull(w.Rotate(), "nothing open");
                Assert.AreEqual(0, w.Unpublished, "published by the next rotation");
                Assert.AreEqual(new string(a), TempDir.Gunzip(final));
                Assert.IsFalse(File.Exists(final + ".tmp"));
            }
        }

        static void Gzip(string path, string text)
        {
            using (var f = File.Create(path))
            using (var g = new System.IO.Compression.GZipStream(f, System.IO.Compression.CompressionMode.Compress))
            {
                var b = Encoding.UTF8.GetBytes(text);
                g.Write(b, 0, b.Length);
            }
        }

        [TestCase("{}")]
        [TestCase("{\"session\":\"test\",\"format\":1,\"counts\":{\"format\":9}}")]
        public void RecoveryPublishesWholeTmpFilesAndDropsTornOnesEvenInFinishedSessions(string metadata)
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path);
                var dir = store.SessionOutbox(S1);
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, FileChunkStore.MetaFile), metadata);
                var marker = Path.Combine(dir, DoneMarker.FileName);
                File.WriteAllText(marker, "{}");
                Gzip(Path.Combine(dir, "chunk-0001.jsonl.gz.tmp"), "{\"k\":\"f\"}\n");         // rename failed: whole
                File.WriteAllBytes(Path.Combine(dir, "chunk-0002.jsonl.gz.tmp"), new byte[] { 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 1, 2 }); // torn
                var corrupt = Path.Combine(dir, "chunk-0004.jsonl.gz.tmp");
                Gzip(corrupt, "{\"k\":\"corrupt\"}\n");
                var bytes = File.ReadAllBytes(corrupt);
                bytes[10] = 0xff; // invalid DEFLATE block type, with a complete gzip header and trailer
                File.WriteAllBytes(corrupt, bytes);
                Gzip(Path.Combine(dir, "chunk-0003.jsonl.gz"), "{\"k\":\"original\"}\n");
                Gzip(Path.Combine(dir, "chunk-0003.jsonl.gz.tmp"), "{\"k\":\"duplicate\"}\n");
                store.RecoverChunks();
                Assert.AreEqual(0, Directory.GetFiles(dir, "*.tmp").Length);
                Assert.AreEqual("{\"k\":\"f\"}\n", TempDir.Gunzip(Path.Combine(dir, "chunk-0001.jsonl.gz")));
                Assert.IsFalse(File.Exists(Path.Combine(dir, "chunk-0002.jsonl.gz")));
                Assert.AreEqual("{\"k\":\"original\"}\n", TempDir.Gunzip(Path.Combine(dir, "chunk-0003.jsonl.gz")));
                Assert.IsFalse(File.Exists(Path.Combine(dir, "chunk-0004.jsonl.gz")));
                Assert.AreEqual("{}", File.ReadAllText(marker));
            }
        }

        [Test]
        public void ARecoveryRenameFailureLeavesTheCompleteTempForTheNextAttempt()
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path);
                store.CreateSession(S1);
                var final = Path.Combine(store.SessionOutbox(S1), "chunk-0001.jsonl.gz");
                const string text = "{\"k\":\"start\"}\n";
                Gzip(final + ".tmp", text);
                Directory.CreateDirectory(final);
                Assert.Catch<System.Exception>(() => store.RecoverChunks());
                Assert.AreEqual(text, TempDir.Gunzip(final + ".tmp"));
                Directory.Delete(final);
                store.RecoverChunks();
                Assert.AreEqual(text, TempDir.Gunzip(final));
            }
        }

        [Test]
        public void SessionCreationRejectsExistingDirectories()
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path);
                Directory.CreateDirectory(store.SessionOutbox(S1));
                Assert.Throws<IOException>(() => store.CreateSession(S1));
                Assert.IsEmpty(Directory.GetFileSystemEntries(store.SessionOutbox(S1)));
            }
        }

        [Test]
        public void SessionCreationCanBeRetriedAfterSetupFails()
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path);
                File.WriteAllText(store.Outbox, "blocked");
                Assert.Catch<IOException>(() => store.CreateSession(S1));
                File.Delete(store.Outbox);
                store.CreateSession(S1);
                Assert.IsTrue(Directory.Exists(store.SessionOutbox(S1)));
            }
        }
    }
}
