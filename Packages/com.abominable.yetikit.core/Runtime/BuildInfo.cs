using System;
using UnityEngine;

namespace YetiKit.Core
{
    /// <summary>
    /// What build this is (pure apart from <see cref="Current"/>): the build number (first-parent commit count), the short
    /// git SHA, the build time (ISO 8601 UTC, <see cref="BuildTime"/>; older builds baked the UTC day only) and the
    /// "What's new" notes. The consumer build method bakes it into the generated, git-ignored
    /// <c>Assets/Resources/Generated/BuildInfo.json</c> for the player build only; with no such file (Editor, tests) it is
    /// <see cref="Unknown"/>.
    /// </summary>
    public sealed class BuildInfo
    {
        /// <summary>Resources.Load path of the generated TextAsset.</summary>
        public const string ResourcePath = "Generated/BuildInfo";
        public const int MaxNotes = 12, MaxNoteLength = 120;

        public int Number { get; private set; }
        public string Sha { get; private set; } = "dev";
        /// <summary>The baked build time: ISO 8601 UTC (<c>2026-11-02T03:55:00Z</c>), or the UTC day alone from older
        /// builds (<c>2026-11-02</c>), or empty.</summary>
        public string Date { get; private set; } = "";
        public string[] Notes { get; private set; } = new string[0];

        public static readonly BuildInfo Unknown = new BuildInfo();

        public BuildInfo() { }

        public BuildInfo(int number, string sha, DateTime utc, string[] notes)
        {
            Number = Math.Max(0, number);
            Sha = string.IsNullOrWhiteSpace(sha) ? "dev" : sha.Trim();
            Date = BuildTime.Stamp(utc);
            Notes = notes ?? new string[0];
        }

        /// <summary>A numbered build from git (git failed at build time: number 0, not known).</summary>
        public bool Known => Number > 0 && Sha != "dev";

        /// <summary><c>b&lt;number&gt;-&lt;sha7&gt;</c>, or null when not <see cref="Known"/>.</summary>
        public string Id => Known ? "b" + Number + "-" + Sha : null;

        /// <summary>The recorder's build id: <see cref="Id"/> when known, else the old <c>version-guid8</c> form
        /// (<c>editor</c> for the guid in the Editor).</summary>
        public static string BuildId(BuildInfo info, string version, string guid)
        {
            if (info != null && info.Known) return info.Id;
            return version + "-" + (string.IsNullOrEmpty(guid) ? "editor" : guid.Substring(0, Math.Min(8, guid.Length)));
        }

        /// <summary>The header using <see cref="Application.productName"/> (main thread).</summary>
        public string Header(TimeZoneInfo zone = null) => Header(Application.productName, zone);

        /// <summary>The header for <paramref name="productName"/>, with the build time in <paramref name="zone"/>
        /// (null: UTC, marked "UTC").</summary>
        public string Header(string productName, TimeZoneInfo zone = null)
        {
            if (!Known) return productName + " \u00b7 dev build";
            var when = BuildTime.Label(Date, zone);
            return $"{productName} \u00b7 Build {Number} ({Sha})" + (when.Length > 0 ? " \u00b7 " + when : "");
        }

        [Serializable]
        sealed class Raw
        {
            public int number;
            public string sha;
            public string date;
            public string[] notes;
        }

        public string ToJson() => JsonUtility.ToJson(new Raw { number = Number, sha = Sha, date = Date, notes = Notes }, true);

        /// <summary>The baked JSON; null, empty or invalid: <see cref="Unknown"/>.</summary>
        public static BuildInfo Parse(string json)
        {
            if (string.IsNullOrWhiteSpace(json)) return Unknown;
            Raw raw;
            try { raw = JsonUtility.FromJson<Raw>(json); }
            catch (Exception) { return Unknown; }
            if (raw == null) return Unknown;
            return new BuildInfo
            {
                Number = Math.Max(0, raw.number),
                Sha = string.IsNullOrWhiteSpace(raw.sha) ? "dev" : raw.sha.Trim(),
                Date = raw.date ?? "",
                Notes = raw.notes ?? new string[0],
            };
        }

        static BuildInfo current;

        /// <summary>This player's build info, read once from Resources (main thread).</summary>
        public static BuildInfo Current
        {
            get
            {
                if (current != null) return current;
                var asset = Resources.Load<TextAsset>(ResourcePath);
                current = asset ? Parse(asset.text) : Unknown;
                return current;
            }
        }
    }
}
