using System;
using System.IO;
using System.Linq;
using System.Threading;
using NUnit.Framework;

namespace YetiKit.Playtest.Tests
{
    public class DurabilityTests
    {
        const string Id = "20261029-070503-abcd";

        [Test]
        public void InterruptedChunkSalvagesFlushedRecordsAndCountsOneTornTail()
        {
            using (var tmp = new TempDir())
            using (var snapshot = new TempDir())
            using (var pump = new ChunkPump())
            {
                var clock = 0.0;
                var log = new FlightLog(() => clock);
                var store = new FileChunkStore(tmp.Path);
                var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UnixEpoch);
                Assert.IsTrue(session.Begin(0));
                clock = 1;
                log.AppendEvent("kept_one", null);
                log.AppendEvent("kept_two", null);
                session.Tick(1);
                Assert.IsTrue(pump.Drain(5000));

                // Snapshot the files before Rotate/Dispose, as if the process had just died.
                var restarted = new FileChunkStore(snapshot.Path);
                restarted.CreateSession(Id);
                var dir = restarted.SessionOutbox(Id);
                foreach (var file in Directory.GetFiles(session.Dir))
                using (var input = File.Open(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var output = File.Create(Path.Combine(dir, Path.GetFileName(file)))) input.CopyTo(output);
                var journal = Directory.GetFiles(dir, "*.journal").SingleOrDefault();
                Assert.IsNotNull(journal, "the in-flight chunk has a framed journal");
                using (var tail = File.Open(journal, FileMode.Append)) { tail.WriteByte(20); tail.WriteByte(0); }
                restarted.RecoverChunks();
                restarted.RecoverChunks();
                var text = TempDir.Gunzip(Path.Combine(dir, FileChunkStore.ChunkName(1)));
                Assert.AreEqual(3, text.Count(c => c == '\n'));
                StringAssert.Contains("kept_one", text);
                StringAssert.Contains("kept_two", text);
                StringAssert.Contains("\"torn\":1", File.ReadAllText(Path.Combine(dir, FileChunkStore.MetaFile)));
                Assert.IsEmpty(Directory.GetFiles(dir, "*.journal"));
            }
        }

        [Test]
        public void DiskFullPreservesEarlierChunkAndReportsTheExactTimedLoss()
        {
            using (var tmp = new TempDir())
            {
                var full = false;
                var store = new FileChunkStore(tmp.Path);
                using (var pump = new ChunkPump(openFile: path => full ? throw new IOException("disk full") : File.Create(path)))
                {
                    var clock = 0.0;
                    var log = new FlightLog(() => clock);
                    var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UnixEpoch);
                    Assert.IsTrue(session.Begin(0));
                    log.AppendEvent("before", null);
                    clock = 60;
                    session.Tick(1);
                    Assert.IsTrue(pump.Drain(5000));
                    var first = Path.Combine(session.Dir, FileChunkStore.ChunkName(1));
                    var prior = File.ReadAllBytes(first);
                    full = true;
                    clock = 61.125;
                    log.AppendEvent("lost_one", null);
                    clock = 62.375;
                    log.AppendEvent("lost_two", null);
                    session.Tick(2);
                    Assert.IsTrue(pump.Drain(5000));
                    full = false;
                    Assert.IsTrue(session.End(3));
                    Assert.IsTrue(pump.Drain(5000));
                    CollectionAssert.AreEqual(prior, File.ReadAllBytes(first));
                    StringAssert.Contains("\"lost\":{\"count\":2,\"first\":61.125,\"last\":62.375", File.ReadAllText(Path.Combine(session.Dir, FileChunkStore.MetaFile)));
                }
            }
        }

        [Test]
        public void SlowWorkerBackpressuresTheProducerAndCheckpointsDroppedTimes()
        {
            using (var tmp = new TempDir())
            using (var entered = new ManualResetEventSlim())
            using (var release = new ManualResetEventSlim())
            using (var pump = new ChunkPump(openFile: path =>
            {
                entered.Set();
                if (!release.Wait(10000)) throw new IOException("test did not release the worker");
                return File.Create(path);
            }))
            {
                var store = new FileChunkStore(tmp.Path);
                var clock = 0.0;
                var log = new FlightLog(() => clock, maxBufferedChars: 128);
                var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UnixEpoch);
                Assert.IsTrue(session.Begin(0));
                try
                {
                    for (var i = 1; i <= ChunkPump.PooledBuilders + 1; i++)
                    {
                        clock = i;
                        Assert.AreEqual(AppendResult.Appended, log.AppendEvent("test", new string('x', 35)));
                        session.Tick(i);
                        if (i == 1) Assert.IsTrue(entered.Wait(5000));
                    }
                    clock = 9;
                    Assert.AreEqual(AppendResult.BufferFull, log.AppendEvent("test", new string('x', 70)));
                    clock = 10;
                    Assert.AreEqual(AppendResult.BufferFull, log.AppendEvent("test", new string('x', 70)));
                    Assert.AreEqual(2, log.BackpressureDrops);
                    Assert.IsTrue(session.End(11));
                    Assert.AreEqual(AppendResult.Sealed, log.AppendEvent("test", null));
                }
                finally { release.Set(); }
                Assert.IsTrue(pump.Drain(5000));
                StringAssert.Contains("\"lost\":{\"count\":2,\"first\":9,\"last\":10", File.ReadAllText(Path.Combine(session.Dir, FileChunkStore.MetaFile)));
                Assert.That(TempDir.Gunzip(Path.Combine(session.Dir, FileChunkStore.ChunkName(1))).Count(c => c == '\n'), Is.EqualTo(5));
                var marker = File.ReadAllText(Path.Combine(session.Dir, DoneMarker.FileName));
                StringAssert.Contains("\"lostRecords\":2", marker);
                Assert.AreEqual(0, DoneMarker.Parse(marker).context.lost, "rejected records are not a character count");
            }
        }

        [Test]
        public void AppendReportsThatTheProducerBufferIsFull()
        {
            var log = new FlightLog(() => 0);
            Assert.AreEqual(AppendResult.BufferFull, log.AppendEvent("large", new string('x', FlightLog.InitialChars * 2)));
            Assert.AreEqual(1, log.BackpressureDrops);
            Assert.AreEqual(0, log.Buffer.Length);
        }
    }
}
