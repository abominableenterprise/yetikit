using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace YetiKit.Quality.Editor
{
    public static class GuidCollisionCheck
    {
        public static List<(string guid, string[] paths)> Find(params string[] roots)
        {
            var files = new HashSet<string>(StringComparer.Ordinal);
            foreach (var root in roots)
            {
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);
                foreach (var file in Directory.EnumerateFiles(root, "*.meta", SearchOption.AllDirectories))
                    files.Add(Path.GetFullPath(file));
            }
            return files.Select(path => (path, match: Regex.Match(File.ReadAllText(path), @"^guid:\s*([0-9a-fA-F]{32})\s*$", RegexOptions.Multiline)))
                .Where(item => item.match.Success)
                .GroupBy(item => item.match.Groups[1].Value.ToLowerInvariant())
                .Where(group => group.Count() > 1)
                .OrderBy(group => group.Key, StringComparer.Ordinal)
                .Select(group => (group.Key, group.Select(item => item.path).OrderBy(p => p, StringComparer.Ordinal).ToArray())).ToList();
        }
    }
}
