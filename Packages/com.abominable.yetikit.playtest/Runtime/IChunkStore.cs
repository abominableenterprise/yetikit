using System;
using System.IO;

namespace YetiKit.Playtest
{
    /// <summary>Local session layout and publication operations for the recording worker.</summary>
    public interface IChunkStore
    {
        string SessionOutbox(string session);
        /// <summary>Create a new session, throwing <see cref="IOException"/> if it already exists.</summary>
        void CreateSession(string session);
        int NextFree(string dir);
        (string temp, string final) ChunkPaths(string dir, int index);
        Stream OpenTemp(string path, Func<string, Stream> openFile);
        bool TempExists(string path);
        long TempLength(string path);
        void DeleteTemp(string path);
        void PublishChunk(string temp, string final);
        void PublishFile(string path, byte[] bytes);
        void DeleteDir(string dir);
    }
}
