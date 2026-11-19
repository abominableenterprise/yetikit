using System;
using System.IO;

namespace YetiKit.Playtest
{
    /// <summary>
    /// A write-only pass-through that remembers its first failure. Mono's GZipStream swallows an exception from the
    /// underlying stream while it disposes (the trailer write), so <see cref="ChunkWriter"/> checks <see cref="Failure"/>
    /// to know whether a chunk is really whole.
    /// </summary>
    public sealed class WriteGuardStream : Stream
    {
        readonly Stream inner;
        public Exception Failure { get; private set; }

        public WriteGuardStream(Stream inner) => this.inner = inner;

        public override void Write(byte[] buffer, int offset, int count)
        {
            try { inner.Write(buffer, offset, count); }
            catch (Exception e) { Failure = Failure ?? e; throw; }
        }

        public override void Flush()
        {
            try { if (inner is FileStream f) f.Flush(true); else inner.Flush(); }
            catch (Exception e) { Failure = Failure ?? e; throw; }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) inner.Dispose();
            base.Dispose(disposing);
        }

        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => inner.Length;
        public override long Position { get => inner.Position; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
