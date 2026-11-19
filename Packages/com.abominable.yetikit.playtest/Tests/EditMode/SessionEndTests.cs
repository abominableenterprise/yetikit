using System;
using System.IO;
using System.Threading;
using NUnit.Framework;
using YetiKit.Core;

namespace YetiKit.Playtest.Tests
{
    public class SessionEndTests
    {
        const string A = "20261029-070000-aaaa", B = "20261029-071000-bbbb";
        static readonly DateTime Start = new DateTime(2026, 10, 29, 7, 0, 0, DateTimeKind.Utc);
        double clock;
        DateTime Utc => Start.AddSeconds(clock);

        RecordingSession Session(string id, FlightLog log, ChunkPump pump, FileChunkStore store, Action<string> createDir = null) =>
            new RecordingSession(log, pump, store, new SessionMeta(id), () => Utc, createDir);

        [Test]
        public void AFailedFinalMetaWriteHoldsDoneUntilItsRetrySucceeds()
        {
            using (var tmp = new TempDir())
            {
                var store = new FileChunkStore(tmp.Path);
                var dir = store.SessionOutbox(A);
                var meta = Path.Combine(dir, FileChunkStore.MetaFile);
                var marker = Path.Combine(dir, DoneMarker.FileName);
                var failMeta = false;
                var retryClock = 0.0;
                Action<string, byte[]> write = (path, bytes) =>
                {
                    if (path == meta && failMeta)
                    {
                        failMeta = false;
                        throw new IOException("disk full");
                    }
                    FileChunkStore.WriteAtomic(path, bytes);
                };
                using (var pump = new ChunkPump(null, null, write, () => Volatile.Read(ref retryClock)))
                {
                    clock = 0;
                    var log = new FlightLog(() => clock, new TestEventClassification());
                    var session = Session(A, log, pump, store);
                    Assert.IsTrue(session.Begin(0));
                    Assert.IsTrue(pump.Drain(5000));
                    var initialMeta = File.ReadAllText(meta);
                    StringAssert.Contains("\"end\":null", initialMeta);

                    clock = 30;
                    log.AppendEvent("test_action", null);
                    failMeta = true;
                    Assert.IsTrue(session.End(900));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(1, pump.Errors);
                    Assert.AreEqual(initialMeta, File.ReadAllText(meta));
                    Assert.IsFalse(File.Exists(marker), "no marker before final metadata");
                    Assert.IsTrue(pump.Owns(A), "pending retry");

                    Volatile.Write(ref retryClock, Backoff.Delay(1) - 0.5);
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.IsFalse(File.Exists(marker), "not before the retry delay");
                    Volatile.Write(ref retryClock, Backoff.Delay(1));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.IsFalse(pump.Owns(A));
                    Assert.AreEqual(1, pump.Errors);

                    var text = File.ReadAllText(meta);
                    StringAssert.Contains("\"end\":\"2026-10-29T07:00:30.000Z\"", text);
                    StringAssert.Contains("\"seconds\":30,", text);
                    var done = DoneMarker.Parse(File.ReadAllText(marker));
                    Assert.IsNotNull(done);
                    Assert.AreEqual(A, done.session);
                    Assert.AreEqual(900, done.context.frames);
                }
            }
        }

        [Test]
        public void ALongPauseRolloverWithAStalledPumpKeepsBothSessions()
        {
            using (var tmp = new TempDir())
            using (var entered = new ManualResetEventSlim())
            using (var release = new ManualResetEventSlim())
            {
                var store = new FileChunkStore(tmp.Path);
                var dirA = store.SessionOutbox(A);
                var dirB = store.SessionOutbox(B);
                var metaA = Path.Combine(dirA, FileChunkStore.MetaFile);
                var metaB = Path.Combine(dirB, FileChunkStore.MetaFile);
                var doneA = Path.Combine(dirA, DoneMarker.FileName);
                var doneB = Path.Combine(dirB, DoneMarker.FileName);
                var stallFinalMeta = false;
                Action<string, byte[]> write = (path, bytes) =>
                {
                    if (path == metaA && stallFinalMeta)
                    {
                        entered.Set();
                        if (!release.Wait(10000)) throw new IOException("test did not release the stalled write");
                    }
                    FileChunkStore.WriteAtomic(path, bytes);
                };
                using (var pump = new ChunkPump(null, null, write))
                {
                    clock = 0;
                    var log = new FlightLog(() => clock, new TestEventClassification());
                    var first = Session(A, log, pump, store);
                    Assert.IsTrue(first.Begin(0));
                    clock = 40;
                    log.AppendEvent("test_old", null);
                    first.Pause(1200, 5000);
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.IsTrue(File.Exists(Path.Combine(dirA, "chunk-0001.jsonl.gz")));
                    Assert.IsFalse(File.Exists(doneA), "paused is not finished");

                    clock = 600;
                    Assert.IsFalse(first.Resume());
                    stallFinalMeta = true;
                    try
                    {
                        Assert.IsTrue(first.End(1200));
                        Assert.IsTrue(entered.Wait(5000), "worker reached the final metadata write");
                        var second = Session(B, log, pump, store);
                        Assert.IsTrue(second.Begin(1200));
                        clock = 601.5;
                        log.AppendEvent("test_new", null);
                        second.Tick(1245);
                        clock = 630;
                        Assert.IsTrue(second.End(1300));
                        Assert.IsTrue(pump.Owns(A));
                        Assert.IsTrue(pump.Owns(B));
                        Assert.IsFalse(File.Exists(doneA), "first session still waits for final metadata");
                        Assert.IsFalse(File.Exists(metaB), "second session's writes are queued behind the first");
                        Assert.IsFalse(File.Exists(doneB));
                    }
                    finally { release.Set(); }
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(0, pump.Errors);
                    Assert.IsFalse(pump.Owns(A));
                    Assert.IsFalse(pump.Owns(B));
                    Assert.AreEqual(A, DoneMarker.Parse(File.ReadAllText(doneA)).session);
                    Assert.AreEqual(B, DoneMarker.Parse(File.ReadAllText(doneB)).session);
                    StringAssert.Contains("\"seconds\":40,", File.ReadAllText(metaA));
                    StringAssert.Contains("\"seconds\":30,", File.ReadAllText(metaB));
                    var firstChunk = TempDir.Gunzip(Path.Combine(dirA, "chunk-0001.jsonl.gz"));
                    var secondChunk = TempDir.Gunzip(Path.Combine(dirB, "chunk-0001.jsonl.gz"));
                    StringAssert.Contains("\"k\":\"test_old\"", firstChunk);
                    StringAssert.DoesNotContain("test_new", firstChunk);
                    StringAssert.Contains("\"k\":\"test_new\"", secondChunk);
                    StringAssert.DoesNotContain("test_old", secondChunk);
                }
            }
        }

        [Test]
        public void ABeginWhoseDirectoryFailsChangesNothingAndTheRetryStartsCleanly()
        {
            using (var tmp = new TempDir())
            using (var pump = new ChunkPump())
            {
                clock = 0;
                var store = new FileChunkStore(tmp.Path);
                var log = new FlightLog(() => clock, new TestEventClassification());
                var failOnce = true;
                var session = Session(A, log, pump, store, _ =>
                {
                    if (!failOnce) return;
                    failOnce = false;
                    throw new IOException("no storage");
                });
                clock = 7;
                Assert.IsFalse(session.Begin(0));
                Assert.AreEqual("no storage", session.LastBeginError);
                Assert.IsFalse(session.Begun);
                Assert.AreEqual(7, log.Now, 1e-9, "the clock was not restarted");
                session.Tick(10);
                session.Pause(10, 1000);
                Assert.IsFalse(session.Paused, "not recording: nothing to pause");
                Assert.IsTrue(pump.Drain(5000));
                Assert.IsFalse(Directory.Exists(store.Outbox), "no pump job and no directory");
                Assert.AreEqual(0, pump.Errors);

                Assert.IsTrue(session.Begin(20));
                Assert.IsTrue(session.Begun);
                Assert.IsNull(session.LastBeginError);
                Assert.AreEqual(0, log.Now, 1e-9);
                clock = 25;
                log.AppendEvent("test_action", null);
                Assert.IsTrue(session.End(50));
                Assert.IsTrue(pump.Drain(5000));
                var dir = store.SessionOutbox(A);
                var text = TempDir.Gunzip(Path.Combine(dir, "chunk-0001.jsonl.gz"));
                StringAssert.StartsWith("{\"t\":0,\"k\":\"start\",\"session\":\"" + A + "\"", text);
                StringAssert.Contains("\"frames\":30,", File.ReadAllText(Path.Combine(dir, FileChunkStore.MetaFile)));
                Assert.IsTrue(File.Exists(Path.Combine(dir, DoneMarker.FileName)));
            }
        }
    }
}
