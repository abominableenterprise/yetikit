using System.IO;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public sealed class FormatRecoveryTests
    {
        [TestCase("meta.json")]
        [TestCase("meta.json.tmp")]
        public void RecoveryLeavesAnUnknownFormatSessionIntact(string metadataName)
        {
            using (var tmp = new TempDir())
            {
                const string id = "20260101-000000-0001";
                var store = new FileChunkStore(tmp.Path);
                var dir = store.SessionOutbox(id);
                Directory.CreateDirectory(dir);
                var meta = Path.Combine(dir, metadataName);
                File.WriteAllText(meta, "{\"format\":42,\"session\":\"" + id + "\"}\n");
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
