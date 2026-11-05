using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("YetiKit.Quality.Tests")]

namespace YetiKit.Quality.Editor
{
    public static class GuidCollisionCheck
    {
        public static List<(string guid, string[] paths)> Find(params string[] roots) => Find(
            UnityEngine.Application.platform == UnityEngine.RuntimePlatform.WindowsEditor ||
            UnityEngine.Application.platform == UnityEngine.RuntimePlatform.OSXEditor
                ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal, roots);

        internal static List<(string guid, string[] paths)> Find(IEqualityComparer<string> pathComparer, params string[] roots)
        {
            var scanRoots = new List<string>();
            foreach (var root in roots.Select(PathKey).Distinct(pathComparer).OrderBy(path => path.Length))
            {
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);
                if (scanRoots.Any(parent => IsWithin(root, parent, pathComparer))) continue;
                scanRoots.Add(root);
            }
            var files = new HashSet<string>(pathComparer);
            foreach (var root in scanRoots)
                foreach (var file in Directory.EnumerateFiles(root, "*.meta", SearchOption.AllDirectories))
                    files.Add(PathKey(file));
            return files.Select(path => (path, match: Regex.Match(File.ReadAllText(path), @"^guid:\s*([0-9a-fA-F]{32})\s*$", RegexOptions.Multiline)))
                .Where(item => item.match.Success)
                .GroupBy(item => item.match.Groups[1].Value.ToLowerInvariant())
                .Where(group => group.Count() > 1)
                .OrderBy(group => group.Key, StringComparer.Ordinal)
                .Select(group => (group.Key, group.Select(item => item.path).OrderBy(p => p, StringComparer.Ordinal).ToArray())).ToList();
        }

        static string PathKey(string path)
        {
            var full = Path.GetFullPath(path);
            if (full.Length > Path.GetPathRoot(full).Length)
                full = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return full.Replace(Path.DirectorySeparatorChar, '/').Replace(Path.AltDirectorySeparatorChar, '/');
        }

        static bool IsWithin(string path, string parent, IEqualityComparer<string> comparer)
        {
            var prefix = parent.EndsWith("/", StringComparison.Ordinal) ? parent : parent + "/";
            return path.Length >= prefix.Length && comparer.Equals(path.Substring(0, prefix.Length), prefix);
        }
    }
}
