using System.IO;
using System.Runtime.InteropServices;

namespace YetiKit.Playtest
{
    /// <summary>Flush directory entries after atomic publication on supported Unix filesystems.</summary>
    internal static class DirectoryDurability
    {
#if UNITY_EDITOR_OSX || (!UNITY_EDITOR && UNITY_STANDALONE_OSX)
        const string LibC = "libSystem.B.dylib";
#elif UNITY_EDITOR_LINUX || (!UNITY_EDITOR && (UNITY_STANDALONE_LINUX || UNITY_ANDROID))
        const string LibC = "libc";
#endif

        internal static void Sync(string path)
        {
#if UNITY_EDITOR_LINUX || UNITY_EDITOR_OSX || (!UNITY_EDITOR && (UNITY_STANDALONE_LINUX || UNITY_STANDALONE_OSX || UNITY_ANDROID))
            var fd = Open(path, 0); // O_RDONLY; a directory can be opened for fsync on these platforms.
            if (fd < 0) throw Error("open", Marshal.GetLastWin32Error());
            try
            {
                while (Fsync(fd) != 0)
                {
                    var errno = Marshal.GetLastWin32Error();
                    if (errno == 4) continue; // EINTR
                    if (Unsupported(errno)) return;
                    throw Error("fsync", errno);
                }
            }
            finally { Close(fd); }
#endif
        }

#if UNITY_EDITOR_LINUX || UNITY_EDITOR_OSX || (!UNITY_EDITOR && (UNITY_STANDALONE_LINUX || UNITY_STANDALONE_OSX || UNITY_ANDROID))
        static bool Unsupported(int errno)
        {
            if (errno == 22) return true; // EINVAL: filesystem does not support directory fsync
#if UNITY_EDITOR_OSX || (!UNITY_EDITOR && UNITY_STANDALONE_OSX)
            return errno == 45 || errno == 102; // ENOTSUP, EOPNOTSUPP
#else
            return errno == 95; // ENOTSUP / EOPNOTSUPP
#endif
        }

        static IOException Error(string operation, int errno) =>
            new IOException($"Could not {operation} the recording directory (errno {errno}).");

        [DllImport(LibC, EntryPoint = "open", SetLastError = true)]
        static extern int Open(string path, int flags);
        [DllImport(LibC, EntryPoint = "fsync", SetLastError = true)]
        static extern int Fsync(int fd);
        [DllImport(LibC, EntryPoint = "close")]
        static extern int Close(int fd);
#endif
    }
}
