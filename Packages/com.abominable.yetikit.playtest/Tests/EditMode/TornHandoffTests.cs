using System;
using System.IO;
using NUnit.Framework;

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

        sealed class Disk : IChunkStore
        {
            public readonly FileChunkStore Files;
            readonly string step;
            readonly bool diskFull;
            public bool InJournal, Armed = true;
            public int Injected;

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
            public void DeleteTemp(string path) => Files.DeleteTemp(path);
            public void TruncateJournal(string path, long length) => Files.TruncateJournal(path, length);
            public void PublishFile(string path, byte[] bytes) => Files.PublishFile(path, bytes);
            public void DeleteDir(string dir) => Files.DeleteDir(dir);

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
