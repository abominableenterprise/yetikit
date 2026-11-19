using System;
using System.IO;

namespace YetiKit.Playtest.Tests
{
    /// <summary>A fresh temp directory per test, deleted after.</summary>
    sealed class TempDir : IDisposable
    {
        public readonly string Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "playtest-tests-" + Guid.NewGuid().ToString("N"));
        public TempDir() => Directory.CreateDirectory(Path);
        public void Dispose()
        {
            try { Directory.Delete(Path, true); } catch (IOException) { }
        }

        public static string Gunzip(string file)
        {
            using (var f = File.OpenRead(file))
            using (var g = new System.IO.Compression.GZipStream(f, System.IO.Compression.CompressionMode.Decompress))
            using (var r = new StreamReader(g)) return r.ReadToEnd();
        }
    }
}
