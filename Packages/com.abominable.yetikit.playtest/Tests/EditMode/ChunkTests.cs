using System.IO;
using System.Text;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public class ChunkTests
    {
        [Test]
        public void ChunkNamesAreZeroPadded()
        {
            Assert.AreEqual("chunk-0001.jsonl.gz", FileChunkStore.ChunkName(1));
            Assert.AreEqual("chunk-0123.jsonl.gz", FileChunkStore.ChunkName(123));
            Assert.AreEqual(12, FileChunkStore.ChunkIndex("chunk-0012.jsonl.gz"));
            Assert.AreEqual(-1, FileChunkStore.ChunkIndex("chunk-0012.jsonl.gz.tmp"));
        }

        [Test]
        public void RotationPublishesWholeChunksThatGunzipBackToTheLines()
        {
            using (var tmp = new TempDir())
            {
                var w = new ChunkWriter(tmp.Path);
                Assert.IsNull(w.Rotate(), "nothing written: no chunk");
                var a = "{\"t\":0,\"k\":\"start\"}\n".ToCharArray();
                w.Append(a, a.Length);
                Assert.IsTrue(File.Exists(Path.Combine(tmp.Path, "chunk-0001.jsonl.gz.journal")), "the open chunk is a journal");
                Assert.IsFalse(File.Exists(Path.Combine(tmp.Path, "chunk-0001.jsonl.gz")));
                Assert.AreEqual("chunk-0001.jsonl.gz", w.Rotate());
                var b = "{\"t\":1,\"k\":\"grab\",\"name\":\"sample ü\"}\n".ToCharArray();
                w.Append(b, b.Length);
                w.Append(b, b.Length);
                Assert.AreEqual("chunk-0002.jsonl.gz", w.Rotate());
                Assert.AreEqual(new string(a), TempDir.Gunzip(Path.Combine(tmp.Path, "chunk-0001.jsonl.gz")));
                Assert.AreEqual(new string(b) + new string(b), TempDir.Gunzip(Path.Combine(tmp.Path, "chunk-0002.jsonl.gz")));
                Assert.AreEqual(0, Directory.GetFiles(tmp.Path, "*.tmp").Length);
                Assert.AreEqual(3, new FileChunkStore(tmp.Path).NextFree(tmp.Path));
            }
        }

        [Test]
        public void PumpWritesOnItsThreadAndRoundTrips()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var dir = Path.Combine(tmp.Path, "s");
                var written = 0;
                pump.ChunkWritten += _ => System.Threading.Interlocked.Increment(ref written);
                pump.StartSession(dir);
                var sb = new StringBuilder();
                for (var i = 0; i < 5000; i++) sb.Append("{\"t\":").Append(i).Append(",\"k\":\"f\"}\n");
                pump.Write(new StringBuilder(sb.ToString())); // > one copy block
                pump.Rotate();
                pump.Write(new StringBuilder(sb.ToString(0, 10)));
                pump.Write(new StringBuilder()); // empty: ignored
                pump.WriteFile(Path.Combine(dir, "meta.json"), Encoding.UTF8.GetBytes("{}"));
                Assert.IsTrue(pump.Drain(5000));
                Assert.AreEqual(sb.ToString(), TempDir.Gunzip(Path.Combine(dir, "chunk-0001.jsonl.gz")));
                Assert.AreEqual("{}", File.ReadAllText(Path.Combine(dir, "meta.json")));
                Assert.IsTrue(pump.Stop(5000));
                Assert.AreEqual(sb.ToString(0, 10), TempDir.Gunzip(Path.Combine(dir, "chunk-0002.jsonl.gz")), "stop publishes the open chunk");
                Assert.AreEqual(2, written);
                Assert.AreEqual(0, pump.Errors);
            }
        }

        [TestCase(0)]
        [TestCase(-1)]
        [TestCase(1)]
        public void EmojiAcrossPumpBlockBoundariesRoundTrips(int offset)
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                var dir = Path.Combine(tmp.Path, "s");
                pump.StartSession(dir);
                var log = new FlightLog(() => 0);
                log.AppendEvent("emoji", "{\"text\":\"\"}");
                var prefix = log.Buffer.Length - 3; // insert before the closing quote, brace and newline
                log.Buffer.Insert(prefix, new string('a', ChunkPump.BlockChars - 1 - prefix + offset) + "😀");
                // More than two blocks, with another pair at the next nominal boundary too.
                log.Buffer.Insert(log.Buffer.Length - 3, new string('b', ChunkPump.BlockChars - 2) + "🚀");
                var expected = log.Buffer.ToString();
                pump.Write(log.Buffer);
                pump.Rotate();
                Assert.IsTrue(pump.Drain(5000));
                Assert.AreEqual(expected, TempDir.Gunzip(Path.Combine(dir, "chunk-0001.jsonl.gz")));
                Assert.AreEqual(0, pump.Errors);
            }
        }

        [Test]
        public void ChunkNumbersDoNotReuseAnUnpublishedChunk()
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path);
                const string id = "20260101-000000-0001";
                store.CreateSession(id);
                var dir = store.SessionOutbox(id);
                File.WriteAllText(Path.Combine(dir, "chunk-0003.jsonl.gz"), "");
                File.WriteAllText(Path.Combine(dir, "chunk-0004.jsonl.gz.tmp"), "");
                Assert.AreEqual(5, store.NextFree(dir));
            }
        }
    }
}
