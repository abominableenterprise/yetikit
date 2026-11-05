using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using YetiKit.Core;

namespace YetiKit.Core.Editor
{
    /// <summary>
    /// "What's new" bullets (pure): from a notes file (one per line, "- " or "* " or plain) or, when there is none, from
    /// first-parent merge commits (<see cref="GitFormat"/>: subject, a unit separator, the body's first line, a record
    /// separator). "Merge pull request #N from ..." becomes its PR title (the body's first line); a plain merge subject
    /// ("Merge branch 'x' into main") stays out. At most <see cref="BuildInfo.MaxNotes"/>, each cut to
    /// <see cref="BuildInfo.MaxNoteLength"/> chars.
    /// </summary>
    public static class ReleaseNotes
    {
        public const string Field = "\u001f", Record = "\u001e";
        /// <summary>The <c>git log --format</c> that <see cref="FromMerges"/> reads.</summary>
        public const string GitFormat = "%s%x1f%b%x1e";
        public const int DefaultMerges = 8;

        static readonly Regex PullRequest = new Regex(@"^Merge pull request #\d+ from \S+", RegexOptions.CultureInvariant);
        static readonly Regex Bullet = new Regex(@"^\s*(?:[-*\u2022]\s+)?", RegexOptions.CultureInvariant);

        /// <summary>The notes file's lines as bullets (blank lines and "#" comments skipped).</summary>
        public static string[] FromText(string text)
        {
            var notes = new List<string>();
            foreach (var raw in (text ?? "").Replace("\r", "").Split('\n'))
            {
                if (raw.TrimStart().StartsWith("#", StringComparison.Ordinal)) continue;
                Add(notes, Bullet.Replace(raw, ""));
            }
            return notes.ToArray();
        }

        /// <summary>The PR titles of <c>git log --first-parent --merges --format=</c><see cref="GitFormat"/> output.</summary>
        public static string[] FromMerges(string log)
        {
            var notes = new List<string>();
            foreach (var record in (log ?? "").Split(new[] { Record }, StringSplitOptions.None))
            {
                var parts = record.Split(new[] { Field }, 2, StringSplitOptions.None);
                var subject = parts[0].Trim();
                if (subject.Length == 0) continue;
                var body = parts.Length > 1 ? FirstLine(parts[1]) : "";
                if (PullRequest.IsMatch(subject)) Add(notes, body);
                else if (!subject.StartsWith("Merge ", StringComparison.Ordinal)) Add(notes, subject);
            }
            return notes.ToArray();
        }

        static string FirstLine(string text)
        {
            foreach (var line in text.Replace("\r", "").Split('\n'))
                if (line.Trim().Length > 0) return line.Trim();
            return "";
        }

        static void Add(List<string> notes, string note)
        {
            note = Regex.Replace(note ?? "", @"\s+", " ").Trim();
            if (note.Length == 0 || notes.Count >= BuildInfo.MaxNotes) return;
            if (note.Length > BuildInfo.MaxNoteLength) note = note.Substring(0, BuildInfo.MaxNoteLength - 1).TrimEnd() + "\u2026";
            notes.Add(note);
        }
    }
}
