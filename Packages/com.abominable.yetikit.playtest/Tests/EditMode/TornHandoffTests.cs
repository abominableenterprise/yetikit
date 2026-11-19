using System;
using System.IO;
using System.Text;
using System.Threading;
using NUnit.Framework;
using YetiKit.Core;

namespace YetiKit.Playtest.Tests
{
    public class TornHandoffTests
    {
        const string Id = "20261029-070503-abcd";
        const string First = "{\"t\":1,\"k\":\"first\"}\n", Second = "{\"t\":2,\"k\":\"second\"}\n";

        [TestCase("create", false)]
        [TestCase("create", true)]
        [TestCase("write", false)]
        [TestCase("write", true)]
        [TestCase("flush", false)]
        [TestCase("flush", true)]
        [TestCase("rename", false)]
        [TestCase("rename", true)]
        public void PublicationFaultLeavesCommittedFramesRecoverable(string step, bool diskFull)
        {
            using (var tmp = new TempDir())
            {
                var store = new Disk(tmp.Path, step, diskFull);
                store.Files.CreateSession(Id);
                var dir = store.SessionOutbox(Id);
                var writer = new ChunkWriter(dir, store: store);
                writer.Append(First.ToCharArray(), First.Length);
                writer.Append(Second.ToCharArray(), Second.Length);
                Assert.Throws<IOException>(() => writer.Rotate());
                Assert.That(store.Injected, Is.EqualTo(1));
                Assert.IsEmpty(Directory.GetFiles(dir, "*.jsonl.gz"));
                Assert.That(Directory.GetFiles(dir, "*.journal").Length, Is.EqualTo(1));
                store.Files.RecoverChunks();
                store.Files.RecoverChunks();
                Assert.That(TempDir.Gunzip(Path.Combine(dir, FileChunkStore.ChunkName(1))), Is.EqualTo(First + Second));
                Assert.IsEmpty(Directory.GetFiles(dir, "*.journal"));
                Assert.IsEmpty(Directory.GetFiles(dir, "*.tmp"));
            }
        }

        [TestCase("write", false)]
        [TestCase("write", true)]
        [TestCase("flush", false)]
        [TestCase("flush", true)]
        public void JournalFaultRollsBackOnlyTheUncommittedRecord(string step, bool diskFull)
        {
            using (var tmp = new TempDir())
            {
                var store = new Disk(tmp.Path, step, diskFull) { InJournal = true, Armed = false };
                store.Files.CreateSession(Id);
                var dir = store.SessionOutbox(Id);
                using (var writer = new ChunkWriter(dir, store: store))
                {
                    writer.Append(First.ToCharArray(), First.Length);
                    store.Armed = true;
                    Assert.Throws<IOException>(() => writer.Append(Second.ToCharArray(), Second.Length));
                    store.Armed = false;
                    writer.Append(Second.ToCharArray(), Second.Length);
                    writer.Rotate();
                }
                Assert.That(store.Injected, Is.EqualTo(1));
                Assert.That(TempDir.Gunzip(Path.Combine(dir, FileChunkStore.ChunkName(1))), Is.EqualTo(First));
                Assert.That(TempDir.Gunzip(Path.Combine(dir, FileChunkStore.ChunkName(2))), Is.EqualTo(Second));
                Assert.IsEmpty(Directory.GetFiles(dir, "*.journal"));
                Assert.IsEmpty(Directory.GetFiles(dir, "*.tmp"));
            }
        }

        [TestCase(false)]
        [TestCase(true)]
        public void FailedJournalRollbackBlocksCompletionUntilCleanupSucceeds(bool hasCommittedRecord)
        {
            using (var tmp = new TempDir())
            {
                const string next = "20261029-070504-abcd";
                double retryClock = 0;
                var store = new Disk(tmp.Path, "flush", false) { InJournal = true, Armed = !hasCommittedRecord, BlockRollback = true };
                store.CreateSession(Id);
                store.CreateSession(next);
                var dir = store.SessionOutbox(Id);
                var final = Path.Combine(dir, FileChunkStore.ChunkName(1));
                var marker = Path.Combine(dir, DoneMarker.FileName);
                using (var pump = new ChunkPump(store: store, clock: () => Volatile.Read(ref retryClock)))
                {
                    pump.StartSession(dir);
                    if (hasCommittedRecord)
                    {
                        Assert.IsTrue(pump.Write(new StringBuilder(First)));
                        Assert.IsTrue(pump.Drain(5000));
                        store.Armed = true;
                    }
                    Assert.IsTrue(pump.Write(new StringBuilder(Second)));
                    pump.Rotate();
                    pump.Finish(Id, Path.Combine(dir, FileChunkStore.MetaFile), _ => Encoding.UTF8.GetBytes("{\"format\":1}"),
                        marker, _ => Encoding.UTF8.GetBytes("{}"));
                    pump.StartSession(store.SessionOutbox(next));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(1, store.Injected);
                    Assert.Greater(store.RollbackAttempts, 0);
                    Assert.IsTrue(File.Exists(final + ".journal"));
                    Assert.IsTrue(pump.Owns(Id));
                    Assert.IsFalse(File.Exists(marker));
                    Assert.IsEmpty(Directory.GetFiles(dir, "*.jsonl.gz"));

                    store.BlockRollback = false;
                    Volatile.Write(ref retryClock, Backoff.Delay(1));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.IsTrue(File.Exists(marker));
                    Assert.IsFalse(pump.Owns(Id));
                    store.Files.RecoverChunks();
                    Assert.IsEmpty(Directory.GetFiles(dir, "*.journal"));
                    if (hasCommittedRecord) Assert.AreEqual(First, TempDir.Gunzip(final));
                    Assert.AreEqual(hasCommittedRecord ? 1 : 0, Directory.GetFiles(dir, "*.jsonl.gz").Length);
                }
            }
        }

        [TestCase("write")]
        [TestCase("flush")]
        public void ShutdownRotationFailureLeavesCommittedRecordsRecoverableAndNotLost(string step)
        {
            using (var tmp = new TempDir())
            {
                var store = new Disk(tmp.Path, step, false);
                store.CreateSession(Id);
                var dir = store.SessionOutbox(Id);
                using (var pump = new ChunkPump(store: store))
                {
                    pump.StartSession(dir);
                    Assert.IsTrue(pump.Write(new StringBuilder(First + Second)));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(0, store.Injected, "no rotation yet");
                    Assert.IsTrue(pump.Stop(5000));
                    Assert.AreEqual(1, store.Injected);
                    Assert.AreEqual(1, pump.Errors);
                    Assert.AreEqual(0, pump.Lost, "both records are still recoverable");
                    Assert.IsEmpty(Directory.GetFiles(dir, "*.jsonl.gz"));
                }
                store.Files.RecoverChunks();
                Assert.AreEqual(First + Second, TempDir.Gunzip(Path.Combine(dir, FileChunkStore.ChunkName(1))));
            }
        }

        [Test]
        public void FailedDiscardKeepsOwnershipUntilTheDirectoryIsDeleted()
        {
            using (var tmp = new TempDir())
            {
                double retryClock = 0;
                var store = new Disk(tmp.Path, "delete", false);
                var log = new FlightLog(() => 0);
                using (var pump = new ChunkPump(store: store, clock: () => Volatile.Read(ref retryClock)))
                {
                    var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UnixEpoch);
                    Assert.IsTrue(session.Begin(0));
                    Assert.IsFalse(session.End(0));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(1, store.Injected);
                    Assert.IsTrue(Directory.Exists(session.Dir));
                    Assert.IsTrue(pump.Owns(Id));
                    Assert.IsFalse(session.End(0), "ending again is not needed for the retry");

                    Volatile.Write(ref retryClock, Backoff.Delay(1));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.IsFalse(Directory.Exists(session.Dir));
                    Assert.IsFalse(pump.Owns(Id));
                    Assert.AreEqual(1, pump.Errors);
                }
            }
        }

        [TestCase(false)]
        [TestCase(true)]
        public void FinalChunkRenameIsRetriedWhenTheNextSessionCannotOpenAWriter(bool stop)
        {
            using (var tmp = new TempDir())
            {
                const string next = "20261029-070504-abcd";
                double retryClock = 0;
                var store = new FileChunkStore(tmp.Path);
                var log = new FlightLog(() => 0);
                using (var pump = new ChunkPump(store: store, clock: () => Volatile.Read(ref retryClock),
                    nextFree: dir => dir == store.SessionOutbox(next) ? throw new IOException("writer unavailable") : store.NextFree(dir)))
                {
                    var first = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UnixEpoch);
                    Assert.IsTrue(first.Begin(0));
                    var final = Path.Combine(first.Dir, FileChunkStore.ChunkName(1));
                    var marker = Path.Combine(first.Dir, DoneMarker.FileName);
                    Directory.CreateDirectory(final);
                    log.AppendEvent("test_action", null);
                    Assert.IsTrue(first.End(1));
                    var second = new RecordingSession(log, pump, store, new SessionMeta(next), () => DateTime.UnixEpoch);
                    Assert.IsTrue(second.Begin(0));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual("writer unavailable", pump.LastError);
                    Assert.IsTrue(pump.Owns(Id));
                    Assert.IsFalse(File.Exists(marker));

                    var pending = TempDir.Gunzip(final + ".tmp");
                    Directory.Delete(final);
                    if (stop) Assert.IsTrue(pump.Stop(5000));
                    else
                    {
                        Volatile.Write(ref retryClock, Backoff.Delay(1));
                        Assert.IsTrue(pump.Drain(5000));
                    }
                    Assert.IsTrue(File.Exists(final), "publication does not need a live writer");
                    Assert.AreEqual(pending, TempDir.Gunzip(final));
                    Assert.AreEqual(Id, DoneMarker.Parse(File.ReadAllText(marker)).session);
                    Assert.IsFalse(pump.Owns(Id));
                }
            }
        }

        [Test]
        public void FinalChunkRenameIsRetriedBeforePublishingDoneWithoutANewSession()
        {
            using (var tmp = new TempDir())
            {
                double retryClock = 0;
                var store = new FileChunkStore(tmp.Path);
                var log = new FlightLog(() => 0);
                using (var pump = new ChunkPump(store: store, clock: () => Volatile.Read(ref retryClock)))
                {
                    var session = new RecordingSession(log, pump, store, new SessionMeta(Id), () => DateTime.UnixEpoch);
                    Assert.IsTrue(session.Begin(0));
                    var final = Path.Combine(session.Dir, FileChunkStore.ChunkName(1));
                    var marker = Path.Combine(session.Dir, DoneMarker.FileName);
                    Directory.CreateDirectory(final); // block both the final rename and the immediate retry
                    log.AppendEvent("test_action", null);
                    Assert.IsTrue(session.End(1));
                    Assert.IsTrue(pump.Drain(5000));
                    var pending = TempDir.Gunzip(final + ".tmp");
                    StringAssert.Contains("test_action", pending);
                    Assert.IsTrue(pump.Owns(Id));
                    Assert.IsFalse(File.Exists(marker));

                    Directory.Delete(final);
                    Volatile.Write(ref retryClock, Backoff.Delay(1));
                    Assert.IsTrue(pump.Drain(5000));
                    Assert.AreEqual(pending, TempDir.Gunzip(final));
                    Assert.IsFalse(File.Exists(final + ".tmp"));
                    Assert.AreEqual(Id, DoneMarker.Parse(File.ReadAllText(marker)).session);
                    Assert.IsFalse(pump.Owns(Id));
                    Assert.AreEqual(0, pump.Lost);
                }
            }
        }

        [TestCase(false)]
        [TestCase(true)]
        public void StartupRetriesRollbackThatWasStillBlockedOnShutdown(bool hasCommittedRecord)
        {
            using (var tmp = new TempDir())
            {
                var store = new Disk(tmp.Path, "flush", false) { InJournal = true, Armed = !hasCommittedRecord, BlockRollback = true };
                store.CreateSession(Id);
                var dir = store.SessionOutbox(Id);
                var final = Path.Combine(dir, FileChunkStore.ChunkName(1));
                using (var pump = new ChunkPump(store: store))
                {
                    pump.StartSession(dir);
                    if (hasCommittedRecord)
                    {
                        Assert.IsTrue(pump.Write(new StringBuilder(First)));
                        Assert.IsTrue(pump.Drain(5000));
                        store.Armed = true;
                    }
                    Assert.IsTrue(pump.Write(new StringBuilder(Second)));
                    Assert.IsTrue(pump.Stop(5000));
                    Assert.IsTrue(File.Exists(final + ChunkJournal.Suffix));
                    Assert.AreEqual(Second.Length, pump.Lost);
                }

                store.Files.RecoverChunks();
                store.Files.RecoverChunks();
                Assert.AreEqual(hasCommittedRecord, File.Exists(final));
                if (hasCommittedRecord) Assert.AreEqual(First, TempDir.Gunzip(final));
                Assert.AreEqual(hasCommittedRecord ? new[] { final } : Array.Empty<string>(), Directory.GetFiles(dir));
            }
        }

        sealed class Disk : IChunkStore
        {
            public readonly FileChunkStore Files;
            readonly string step;
            readonly bool diskFull;
            public bool InJournal, Armed = true, BlockRollback;
            public int Injected, RollbackAttempts;

            public Disk(string root, string step, bool diskFull)
            {
                Files = new FileChunkStore(root);
                this.step = step;
                this.diskFull = diskFull;
            }

            bool Fails(string path, string operation) => Armed && Injected == 0 && step == operation &&
                InJournal == path.EndsWith(".journal", StringComparison.Ordinal);

            void Fail()
            {
                Injected++;
                throw diskFull ? new IOException("disk full", unchecked((int)0x80070070)) : new IOException("injected IO failure");
            }

            public Stream OpenTemp(string path, Func<string, Stream> openFile)
            {
                if (Fails(path, "create")) Fail();
                return new FaultStream(Files.OpenTemp(path, openFile), path, this);
            }

            public void PublishChunk(string temp, string final)
            {
                if (Fails(temp, "rename")) Fail();
                Files.PublishChunk(temp, final);
            }

            public string SessionOutbox(string session) => Files.SessionOutbox(session);
            public void CreateSession(string session) => Files.CreateSession(session);
            public int NextFree(string dir) => Files.NextFree(dir);
            public (string temp, string final) ChunkPaths(string dir, int index) => Files.ChunkPaths(dir, index);
            public bool TempExists(string path) => Files.TempExists(path);
            public long TempLength(string path) => Files.TempLength(path);
            public void DeleteTemp(string path)
            {
                if (path.EndsWith(".journal", StringComparison.Ordinal)) CheckRollback();
                Files.DeleteTemp(path);
            }

            public void TruncateJournal(string path, long length)
            {
                CheckRollback();
                Files.TruncateJournal(path, length);
            }

            void CheckRollback()
            {
                if (!BlockRollback) return;
                RollbackAttempts++;
                throw new IOException("journal rollback blocked");
            }
            public void PublishFile(string path, byte[] bytes) => Files.PublishFile(path, bytes);
            public void DeleteDir(string dir)
            {
                if (Fails(dir, "delete")) Fail();
                Files.DeleteDir(dir);
            }

            sealed class FaultStream : Stream
            {
                readonly Stream file;
                readonly string path;
                readonly Disk disk;
                public FaultStream(Stream file, string path, Disk disk) { this.file = file; this.path = path; this.disk = disk; }
                public override bool CanRead => false;
                public override bool CanSeek => false;
                public override bool CanWrite => true;
                public override long Length => file.Length;
                public override long Position { get => file.Position; set => throw new NotSupportedException(); }
                public override int Read(byte[] b, int o, int n) => throw new NotSupportedException();
                public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
                public override void SetLength(long n) => throw new NotSupportedException();
                public override void Flush() { file.Flush(); if (disk.Fails(path, "flush")) disk.Fail(); }
                public override void Write(byte[] b, int o, int n)
                {
                    if (disk.Fails(path, "write")) { file.Write(b, o, n / 2); disk.Fail(); }
                    file.Write(b, o, n);
                }
                protected override void Dispose(bool disposing) { if (disposing) file.Dispose(); base.Dispose(disposing); }
            }
        }
    }
}
