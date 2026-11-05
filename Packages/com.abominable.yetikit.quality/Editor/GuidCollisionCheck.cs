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
            UnityEngine.Application.platform == UnityEngine.RuntimePlatform.OSXEditor,
            GuidPathIdentity.IgnoresCase, roots);

        internal static List<(string guid, string[] paths)> Find(bool defaultIgnoreCase,
            Func<string, bool?> caseProbe, params string[] roots) => Scan(
                root => (caseProbe(root) ?? defaultIgnoreCase) ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal, roots);

        internal static List<(string guid, string[] paths)> Find(IEqualityComparer<string> pathComparer, params string[] roots)
            => Scan(_ => pathComparer, roots);

        static List<(string guid, string[] paths)> Scan(Func<string, IEqualityComparer<string>> comparerForRoot, string[] roots)
        {
            var scanRoots = new List<(string path, IEqualityComparer<string> comparer)>();
            // Resolve aliases BEFORE containment pruning. Probe each root, not the editor platform.
            foreach (var root in roots.Select(root =>
            {
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);
                return GuidPathIdentity.Canonical(root);
            }).OrderBy(path => path.Length))
            {
                var comparer = comparerForRoot(root);
                if (scanRoots.Any(parent => parent.comparer.Equals(comparer) &&
                    (comparer.Equals(root, parent.path) || IsWithin(root, parent.path, comparer)))) continue;
                scanRoots.Add((root, comparer));
            }
            var files = new HashSet<string>(StringComparer.Ordinal);
            var visited = new HashSet<string>(StringComparer.Ordinal);
            // Comparer-specific sets preserve the injected identity seam, without folding sensitive roots.
            var directoryKeys = new Dictionary<IEqualityComparer<string>, HashSet<string>>();
            var fileKeys = new Dictionary<IEqualityComparer<string>, HashSet<string>>();
            foreach (var root in scanRoots)
            {
                if (!directoryKeys.TryGetValue(root.comparer, out var directories))
                {
                    directories = directoryKeys[root.comparer] = new HashSet<string>(root.comparer);
                    fileKeys[root.comparer] = new HashSet<string>(root.comparer);
                }
                var pending = new Stack<string>();
                pending.Push(root.path);
                while (pending.Count > 0)
                {
                    var directory = GuidPathIdentity.Canonical(pending.Pop());
                    if (!directories.Add(directory) || !visited.Add(directory)) continue;
                    foreach (var file in Directory.EnumerateFiles(directory, "*.meta"))
                    {
                        var key = GuidPathIdentity.Canonical(file);
                        if (fileKeys[root.comparer].Add(key)) files.Add(key);
                    }
                    // Canonical visited-directory keys stop links back to an ancestor, and alias subtrees.
                    foreach (var child in Directory.EnumerateDirectories(directory)) pending.Push(child);
                }
            }
            return files.Select(path => (path, match: Regex.Match(File.ReadAllText(path), @"^guid:\s*([0-9a-fA-F]{32})\s*$", RegexOptions.Multiline)))
                .Where(item => item.match.Success)
                .GroupBy(item => item.match.Groups[1].Value.ToLowerInvariant())
                .Where(group => group.Count() > 1)
                .OrderBy(group => group.Key, StringComparer.Ordinal)
                .Select(group => (group.Key, group.Select(item => item.path).OrderBy(p => p, StringComparer.Ordinal).ToArray())).ToList();
        }

        static bool IsWithin(string path, string parent, IEqualityComparer<string> comparer)
        {
            var prefix = parent.EndsWith("/", StringComparison.Ordinal) ? parent : parent + "/";
            return path.Length >= prefix.Length && comparer.Equals(path.Substring(0, prefix.Length), prefix);
        }
    }
}
