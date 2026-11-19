using System;
using System.IO;
using System.IO.Compression;

namespace YetiKit.Playtest
{
    internal static class ChunkJournal
    {
        internal const string Suffix = ".journal";
        internal const int MaxFrameBytes = 4 * 1024 * 1024;

        // Read only complete frames. The original survives every failed attempt to create the gzip.
        internal static bool Publish(IChunkStore store, string temp, string final, Func<string, Stream> open, out long written)
        {
            written = 0;
            var path = final + Suffix;
            if (!store.TempExists(path)) return false;
            bool hasRecords;
            using (var input = File.OpenRead(path))
            using (var reader = new BinaryReader(input))
            {
                hasRecords = ReadFrame(reader, out var count);
                if (!hasRecords || store.TempExists(final)) return hasRecords;
                store.DeleteTemp(temp);
                try
                {
                    using (var output = new WriteGuardStream(store.OpenTemp(temp, open)))
                    {
                        using (var gzip = new GZipStream(output, CompressionLevel.Optimal, true))
                        {
                            var bytes = new byte[64 * 1024];
                            do
                            {
                                while (count > 0)
                                {
                                    var n = input.Read(bytes, 0, Math.Min(bytes.Length, count));
                                    if (n == 0) throw new EndOfStreamException();
                                    gzip.Write(bytes, 0, n);
                                    count -= n;
                                }
                            } while (ReadFrame(reader, out count));
                        }
                        if (output.Failure != null) throw output.Failure;
                        output.Flush();
                    }
                }
                catch
                {
                    store.DeleteTemp(temp);
                    throw;
                }
            }
            var size = store.TempLength(temp);
            store.PublishChunk(temp, final);
            written = size;
            return true;
        }

        internal static bool HasTornTail(string path)
        {
            using (var file = File.OpenRead(path))
            using (var reader = new BinaryReader(file))
            {
                while (ReadFrame(reader, out var count)) file.Position += count;
                return file.Position != file.Length;
            }
        }

        static bool ReadFrame(BinaryReader reader, out int count)
        {
            var file = reader.BaseStream;
            var start = file.Position;
            count = file.Length - start >= 4 ? reader.ReadInt32() : 0;
            if (count > 0 && count <= MaxFrameBytes && count <= file.Length - file.Position) return true;
            file.Position = start;
            return false;
        }
    }
}
