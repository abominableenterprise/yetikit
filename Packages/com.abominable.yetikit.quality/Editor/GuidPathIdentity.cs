using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace YetiKit.Quality.Editor
{
    // Unity's .NET Standard profile lacks ResolveLinkTarget. These filesystem APIs resolve
    // every path component, including directory symlinks and Windows junctions.
    internal static class GuidPathIdentity
    {
        static bool Windows => UnityEngine.Application.platform == UnityEngine.RuntimePlatform.WindowsEditor;

        internal static string Canonical(string path)
        {
            var full = Path.GetFullPath(path);
            string resolved;
            if (Windows)
            {
                using (var handle = CreateFile(full, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
                {
                    if (handle.IsInvalid) throw new IOException("Cannot resolve path: " + full);
                    var buffer = new StringBuilder(512);
                    var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                    if (length >= buffer.Capacity)
                    {
                        buffer.Capacity = checked((int)length + 1);
                        length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                    }
                    if (length == 0 || length >= buffer.Capacity) throw new IOException("Cannot resolve path: " + full);
                    resolved = buffer.ToString();
                    if (resolved.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) resolved = @"\\" + resolved.Substring(8);
                    else if (resolved.StartsWith(@"\\?\", StringComparison.Ordinal)) resolved = resolved.Substring(4);
                }
            }
            else
            {
                var pointer = RealPath(full, IntPtr.Zero);
                if (pointer == IntPtr.Zero) throw new IOException("Cannot resolve path: " + full);
                try { resolved = Marshal.PtrToStringAnsi(pointer); }
                finally { Free(pointer); }
            }
            if (resolved.Length > Path.GetPathRoot(resolved).Length)
                resolved = resolved.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return resolved.Replace(Path.DirectorySeparatorChar, '/').Replace(Path.AltDirectorySeparatorChar, '/');
        }

        // Inspect entries INSIDE the scanned directory, never its parent's case behavior.
        // Stay read-only; empty or uncased contents provide no evidence.
        internal static bool? IgnoresCase(string root)
        {
            try
            {
                var entries = Directory.EnumerateFileSystemEntries(root).Select(Path.GetFileName).ToArray();
                foreach (var name in entries)
                {
                    var flipped = new string(name.Select(c => char.IsUpper(c) ? char.ToLowerInvariant(c) : char.ToUpperInvariant(c)).ToArray());
                    if (name == flipped) continue;
                    var alias = Path.Combine(root, flipped);
                    if (!File.Exists(alias) && !Directory.Exists(alias)) return false;
                    return !entries.Contains(flipped, StringComparer.Ordinal);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return null;
        }

        [DllImport("libc", EntryPoint = "realpath", SetLastError = true)]
        static extern IntPtr RealPath(string path, IntPtr buffer);
        [DllImport("libc", EntryPoint = "free")]
        static extern void Free(IntPtr pointer);
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    }
}
