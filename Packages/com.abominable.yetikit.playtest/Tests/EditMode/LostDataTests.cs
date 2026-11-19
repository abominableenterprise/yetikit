using System;
using System.IO;
using System.Text;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public class LostDataTests
    {
        const string Id = "20261029-070503-abcd";

        sealed class FlakyDisk
        {
            public bool FailOpen, FailWrite;
            public int FailOpens;

            public Stream Open(string path)
            {
                if (FailOpen) throw new IOException("open failed");
                if (FailOpens > 0) { FailOpens--; throw new IOException("open failed"); }
                return new Flaky(this, File.Create(path));
            }

            sealed class Flaky : Stream
            {
                readonly FlakyDisk disk;
                readonly FileStream file;
                public Flaky(FlakyDisk disk, FileStream file) { this.disk = disk; this.file = file; }
                public override void Write(byte[] bytes, int offset, int count)
                {
                    if (disk.FailWrite) throw new IOException("write failed");
                    file.Write(bytes, offset, count);
                }
                public override void Flush() => file.Flush();
                protected override void Dispose(bool disposing) { if (disposing) file.Dispose(); base.Dispose(disposing); }
                public override bool CanRead => false;
                public override bool CanSeek => false;
                public override bool CanWrite => true;
                public override long Length => file.Length;
                public override long Position { get => file.Position; set => throw new NotSupportedException(); }
                public override int Read(byte[] bytes, int offset, int count) => throw new NotSupportedException();
                public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
                public override void SetLength(long length) => throw new NotSupportedException();
            }
        }

        [Test]
        public void AFailedWriteCountsTheLostTextAndTheNextHandoffGoesOn()
        {
            using (var tmp = new TempDir())
            {
                var disk = new FlakyDisk { FailOpen = true };
                using (var pump = new ChunkPump(null, disk.Open))
                {
                    pump.StartSession(tmp.Path);
                    pump.Write(new StringBuilder("{\"k\":\"a\"}\n"));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(10, pump.Lost);
                    disk.FailOpen = false;
                    pump.Write(new StringBuilder("{\"k\":\"b\"}\n"));
                    pump.Rotate();
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(2, pump.Errors, "tried twice");
                    Assert.AreEqual(10, pump.Lost, "the second write is whole");
                    Assert.AreEqual("{\"k\":\"b\"}\n", TempDir.Gunzip(Path.Combine(tmp.Path, "chunk-0003.jsonl.gz")));
                    Assert.AreEqual(0, Directory.GetFiles(tmp.Path, "*.tmp").Length);
                }
            }
        }

        [Test]
        public void AFailedWriteIsRetriedOnceInANewChunk()
        {
            using (var tmp = new TempDir())
            {
                var disk = new FlakyDisk { FailOpens = 1 };
                using (var pump = new ChunkPump(null, disk.Open))
                {
                    pump.StartSession(tmp.Path);
                    pump.Write(new StringBuilder("{\"k\":\"a\"}\n"));
                    pump.Rotate();
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(1, pump.Errors);
                    Assert.AreEqual(0, pump.Lost, "nothing lost");
                    Assert.AreEqual("{\"k\":\"a\"}\n", TempDir.Gunzip(Path.Combine(tmp.Path, "chunk-0002.jsonl.gz")));
                }
            }
        }

        [Test]
        public void AChunkTornAtRotationIsCountedAsLost()
        {
            using (var tmp = new TempDir())
            {
                var disk = new FlakyDisk();
                using (var writer = new ChunkWriter(tmp.Path, 1, null, disk.Open))
                {
                    var line = "{\"t\":0,\"k\":\"test_event\"}\n".ToCharArray();
                    writer.Append(line, line.Length);
                    disk.FailWrite = true;
                    Assert.Catch<IOException>(() => writer.Rotate());
                    Assert.AreEqual(line.Length, writer.Lost);
                    Assert.AreEqual(0, Directory.GetFiles(tmp.Path).Length, "the torn chunk is gone");
                }
            }
        }

        [Test]
        public void MetaAndTheDoneMarkerReportLostRecording()
        {
            using (var tmp = new TempDir())
            {
                var disk = new FlakyDisk();
                using (var pump = new ChunkPump(null, disk.Open))
                {
                    var clock = 0.0;
                    var log = new FlightLog(() => clock, new TestEventClassification());
                    var store = new FileChunkStore(tmp.Path);
                    var start = new DateTime(2026, 10, 29, 7, 5, 3, DateTimeKind.Utc);
                    var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => start.AddSeconds(clock));
                    Assert.IsTrue(session.Begin(0));
                    log.AppendEvent("test_before", null);
                    var lost = log.Buffer.Length;
                    disk.FailOpen = true;
                    clock = 2;
                    session.Tick(10);
                    Assert.IsTrue(pump.Drain(5000));
                    disk.FailOpen = false;
                    clock = 30;
                    log.AppendEvent("test_after", null);
                    Assert.IsTrue(session.End(20));
                    Assert.IsTrue(pump.Drain(5000));

                    var dir = store.SessionOutbox(Id);
                    var marker = DoneMarker.Parse(File.ReadAllText(Path.Combine(dir, DoneMarker.FileName)));
                    Assert.IsNotNull(marker);
                    Assert.AreEqual(lost, marker.context.lost);
                    StringAssert.Contains("\"lost\":" + lost + ",", File.ReadAllText(Path.Combine(dir, FileChunkStore.MetaFile)));
                    StringAssert.Contains("\"k\":\"test_after\"", TempDir.Gunzip(Path.Combine(dir, "chunk-0003.jsonl.gz")), "later lines kept");
                }
            }
        }

        [Test]
        public void PrettyPrintedEventDataStaysOnOneLine()
        {
            var log = new FlightLog(() => 0);
            log.AppendEvent("test_object", "{\n  \"text\": \"a\\nb\",\r\n  \"xs\": [1,\n 2]\n}");
            log.AppendEvent("test_list", "[\n1,\n2\n]");
            Assert.AreEqual("{\"t\":0,\"k\":\"test_object\",\"text\": \"a\\nb\",    \"xs\": [1,  2]}\n" +
                "{\"t\":0,\"k\":\"test_list\",\"d\":[ 1, 2 ]}\n", log.Buffer.ToString());
        }
    }
}
