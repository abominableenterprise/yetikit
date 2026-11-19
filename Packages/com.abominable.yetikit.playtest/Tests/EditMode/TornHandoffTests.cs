using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Playtest.Tests
{
    /// <summary>A disk error part-way through a multi-block handoff never publishes half a JSON line: the retry restarts
    /// the whole handoff in a fresh chunk, and Lost counts only what is really dropped.</summary>
    public class TornHandoffTests
    {
        /// <summary>Fails a chunk's write once more than <see cref="FailAfter"/> compressed bytes reached that file, for
        /// the next <see cref="Fails"/> chunks.</summary>
        sealed class FailingDisk
        {
            public long FailAfter = long.MaxValue;
            public int Fails;
            public long FailedAt = -1; // bytes the file had taken when it failed

            public Stream Open(string path) => new Guarded(this, File.Create(path));

            sealed class Guarded : Stream
            {
                readonly FailingDisk disk;
                readonly FileStream f;
                long written;
                bool broken; // a failed file keeps failing (the gzip dispose writes again) but counts once
                public Guarded(FailingDisk d, FileStream f) { disk = d; this.f = f; }
                public override void Write(byte[] b, int o, int n)
                {
                    if (broken) throw new IOException("disk full");
                    if (disk.Fails > 0 && written + n > disk.FailAfter)
                    {
                        disk.Fails--;
                        broken = true;
                        disk.FailedAt = written;
                        throw new IOException("disk full");
                    }
                    f.Write(b, o, n);
                    written += n;
                }
                public override void Flush() => f.Flush();
                protected override void Dispose(bool d) { if (d) f.Dispose(); base.Dispose(d); }
                public override bool CanRead => false;
                public override bool CanSeek => false;
                public override bool CanWrite => true;
                public override long Length => f.Length;
                public override long Position { get => f.Position; set => throw new NotSupportedException(); }
                public override int Read(byte[] b, int o, int n) => throw new NotSupportedException();
                public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
                public override void SetLength(long v) => throw new NotSupportedException();
            }
        }

        [Serializable]
        public class Line
        {
            public int i = -1;
            public string p;
        }

        /// <summary>Lines <c>{"i":N,"p":"hex"}</c> numbered from <paramref name="first"/>, about <paramref name="chars"/>
        /// long in all; hex padding barely compresses, so the gzip reaches the disk while the handoff is written.</summary>
        static string Lines(int first, int chars, int seed, int pad = 87)
        {
            var rng = new System.Random(seed);
            var sb = new StringBuilder();
            for (var i = first; sb.Length < chars; i++)
            {
                sb.Append("{\"i\":").Append(i).Append(",\"p\":\"");
                for (var k = 0; k < pad; k++) sb.Append("0123456789abcdef"[rng.Next(16)]);
                sb.Append("\"}\n");
            }
            return sb.ToString();
        }

        /// <summary>The compressed size of <paramref name="text"/>: a file that took more than this has had text past it.</summary>
        static long GzipLength(string text)
        {
            using (var m = new MemoryStream())
            {
                using (var g = new GZipStream(m, System.IO.Compression.CompressionLevel.Optimal, true))
                {
                    var b = Encoding.UTF8.GetBytes(text);
                    g.Write(b, 0, b.Length);
                }
                return m.Length;
            }
        }

        /// <summary>Every published chunk, decompressed, is whole JSON lines (each one parses); returns them in order.</summary>
        static string[] PublishedLines(string dir)
        {
            Assert.AreEqual(0, Directory.GetFiles(dir, "*.tmp").Length, "no torn chunk left behind");
            var all = new System.Collections.Generic.List<string>();
            var chunks = Directory.GetFiles(dir, "chunk-*.jsonl.gz");
            Array.Sort(chunks, StringComparer.Ordinal);
            foreach (var chunk in chunks)
            {
                var text = TempDir.Gunzip(chunk);
                var name = Path.GetFileName(chunk);
                Assert.IsTrue(text.EndsWith("\n"), name + " ends with a whole line");
                foreach (var line in text.Substring(0, text.Length - 1).Split('\n'))
                {
                    StringAssert.StartsWith("{\"i\":", line, name + " has a line that starts mid-record");
                    StringAssert.EndsWith("\"}", line, name + " has a line that ends mid-record");
                    Line parsed = null;
                    Assert.DoesNotThrow(() => parsed = JsonUtility.FromJson<Line>(line), name + ": " + line);
                    Assert.GreaterOrEqual(parsed.i, 0, name + ": " + line);
                    all.Add(line);
                }
            }
            return all.ToArray();
        }

        [Test]
        public void AFailureAfterTheFirstBlockRetriesTheWholeHandoffFromALineStart()
        {
            using (var tmp = new TempDir())
            {
                var earlier = Lines(0, 2000, 1);              // an earlier handoff in the open chunk: torn with it
                var handoff = Lines(1000, 96 * 1024, 2);      // the usual handoff: 3 blocks, a line across each boundary
                Assert.AreNotEqual('\n', handoff[ChunkPump.BlockChars - 1], "the first block ends mid-line");
                var disk = new FailingDisk { Fails = 1, FailAfter = GzipLength(earlier + handoff.Substring(0, ChunkPump.BlockChars)) };
                using (var pump = new ChunkPump(null, disk.Open))
                {
                    pump.StartSession(tmp.Path);
                    pump.Write(new StringBuilder(earlier));
                    pump.Write(new StringBuilder(handoff));
                    pump.Rotate();
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(1, pump.Errors, pump.LastError);
                    Assert.Greater(disk.FailedAt, 0, "the failure came after the first block was written");
                    Assert.AreEqual(earlier.Length, pump.Lost, "only the torn chunk's earlier handoff is lost");
                    Assert.AreEqual(handoff, TempDir.Gunzip(Path.Combine(tmp.Path, "chunk-0002.jsonl.gz")), "the whole handoff, once");
                    Assert.AreEqual(handoff.Split('\n').Length - 1, PublishedLines(tmp.Path).Length);
                }
            }
        }

        [Test]
        public void AFailureInTheMiddleOfALineNeverPublishesItsTail()
        {
            using (var tmp = new TempDir())
            {
                var line = Lines(7, 1, 3, 3 * ChunkPump.BlockChars); // one line over 3 blocks: every cut is mid-line
                var disk = new FailingDisk { Fails = 1, FailAfter = GzipLength(line.Substring(0, ChunkPump.BlockChars)) };
                using (var pump = new ChunkPump(null, disk.Open))
                {
                    pump.StartSession(tmp.Path);
                    pump.Write(new StringBuilder(line));
                    pump.Rotate();
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(1, pump.Errors, pump.LastError);
                    Assert.Greater(disk.FailedAt, 0, "the failure came after the first block was written");
                    Assert.AreEqual(0, pump.Lost, "nothing lost: the retry wrote the line whole");
                    Assert.AreEqual(new[] { line.TrimEnd('\n') }, PublishedLines(tmp.Path));
                }
            }
        }

        [Test]
        public void ARetryThatFailsTooDropsTheWholeHandoffAndTheNextChunkStartsOnALine()
        {
            using (var tmp = new TempDir())
            {
                var earlier = Lines(0, 2000, 4);
                var handoff = Lines(1000, 96 * 1024, 5);
                var next = Lines(5000, 3000, 6);
                var disk = new FailingDisk { Fails = 2, FailAfter = GzipLength(handoff.Substring(0, ChunkPump.BlockChars)) };
                using (var pump = new ChunkPump(null, disk.Open))
                {
                    pump.StartSession(tmp.Path);
                    pump.Write(new StringBuilder(earlier));
                    pump.Write(new StringBuilder(handoff));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(2, pump.Errors, pump.LastError);
                    Assert.AreEqual(earlier.Length + handoff.Length, pump.Lost, "both handoffs, each counted once");
                    pump.Write(new StringBuilder(next));
                    pump.Rotate();
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(earlier.Length + handoff.Length, pump.Lost, "the next handoff is whole");
                    Assert.AreEqual(next, TempDir.Gunzip(Path.Combine(tmp.Path, "chunk-0003.jsonl.gz")));
                    Assert.AreEqual(next.Split('\n').Length - 1, PublishedLines(tmp.Path).Length);
                }
            }
        }
    }
}
