using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using YetiKit.Core;
using UnityEditor;
using Debug = UnityEngine.Debug;

namespace YetiKit.Core.Editor
{
    /// <summary>
    /// Bakes <see cref="BuildInfo"/> into a player build: the build number (<c>git rev-list --count --first-parent
    /// HEAD</c>), the short SHA, the UTC build time (ISO 8601) and the notes (env <see cref="NotesEnv"/>: a UTF-8 file; else the merges
    /// since <see cref="PrevShaEnv"/>, else the last 8). <see cref="For"/> writes the git-ignored
    /// <see cref="AssetPath"/> and sets bundleVersion "1.0.&lt;n&gt;" / versionCode n until disposed, then deletes the
    /// file and restores both, so nothing in git changes. Git failing never fails the build: number 0 and a warning.
    /// </summary>
    public static class BuildStamp
    {
        public const string AssetPath = "Assets/Resources/Generated/BuildInfo.json";
        public const string NotesEnv = "YETIKIT_WHATS_NEW", PrevShaEnv = "YETIKIT_PREV_SHA";

        /// <summary>Runs git with the arguments in the project folder; null on any failure (tests replace it).</summary>
        public static Func<string, string> Git = RunGit;
        public static Func<string, string> Env = Environment.GetEnvironmentVariable;

        /// <summary>The build info for HEAD (git failing or incomplete history: number 0, "dev", a warning).</summary>
        public static BuildInfo Collect(DateTime utc, string notesEnv = NotesEnv, string prevShaEnv = PrevShaEnv)
        {
            var count = Git("rev-list --count --first-parent HEAD");
            var sha = Git("rev-parse --short=7 HEAD");
            var history = Git("rev-parse --is-shallow-repository");
            if (!int.TryParse(count?.Trim(), out var number) || string.IsNullOrWhiteSpace(sha) || history?.Trim() != "false")
            {
                Debug.LogWarning("[BuildStamp] git failed or full Git history unavailable: build number 0 (the build goes on)");
                number = 0;
                sha = null;
            }
            return new BuildInfo(number, sha?.Trim(), utc, Notes(notesEnv, prevShaEnv));
        }

        static string[] Notes(string notesEnv, string prevShaEnv)
        {
            var file = Env(notesEnv);
            if (!string.IsNullOrWhiteSpace(file))
            {
                try
                {
                    return ReleaseNotes.FromText(File.ReadAllText(file, Encoding.UTF8));
                }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException)
                {
                    Debug.LogWarning($"[BuildStamp] cannot read {notesEnv}={file}: {e.Message}; using the merge titles");
                }
            }
            var prev = Env(prevShaEnv)?.Trim();
            var log = $"log --first-parent --merges --format={ReleaseNotes.GitFormat} ";
            var merges = !string.IsNullOrEmpty(prev) && IsSha(prev) ? Git(log + prev + "..HEAD") : null;
            return ReleaseNotes.FromMerges(merges ?? Git(log + "-n " + ReleaseNotes.DefaultMerges + " HEAD"));
        }

        static bool IsSha(string s)
        {
            if (s.Length < 7 || s.Length > 40) return false;
            foreach (var c in s) if (!Uri.IsHexDigit(c)) return false;
            return true;
        }

        /// <summary>Stamp the build with <paramref name="info"/> until disposed (file written, version set).</summary>
        public static IDisposable For(BuildInfo info, string assetPath = AssetPath)
        {
            ValidatePath(assetPath);
            return Stamp(info, () =>
            {
                Directory.CreateDirectory(Path.GetDirectoryName(assetPath));
                File.WriteAllText(assetPath, info.ToJson(), new UTF8Encoding(false));
                AssetDatabase.ImportAsset(assetPath, ImportAssetOptions.ForceSynchronousImport);
            }, assetPath);
        }

        // Keep the setup boundary injectable without exposing build-only operations in the public API.
        static IDisposable Stamp(BuildInfo info, Action setup, string assetPath)
        {
            var version = PlayerSettings.bundleVersion;
            var code = PlayerSettings.Android.bundleVersionCode;
            var undo = new Undo(() =>
            {
                try { PlayerSettings.bundleVersion = version; }
                finally
                {
                    try { PlayerSettings.Android.bundleVersionCode = code; }
                    finally { Remove(assetPath); }
                }
            });
            try
            {
                if (info.Number > 0)
                {
                    PlayerSettings.bundleVersion = "1.0." + info.Number;
                    PlayerSettings.Android.bundleVersionCode = info.Number;
                }
                setup();
                Debug.Log($"[BuildStamp] build {info.Number} ({info.Sha}), {info.Notes.Length} notes, version {PlayerSettings.bundleVersion}");
                return undo;
            }
            catch
            {
                try { undo.Dispose(); }
                catch (Exception e) { Debug.LogWarning("[BuildStamp] cleanup failed: " + e.Message); }
                throw;
            }
        }

        static void ValidatePath(string assetPath)
        {
            if (string.IsNullOrEmpty(assetPath) || !assetPath.StartsWith("Assets/", StringComparison.Ordinal) ||
                !assetPath.EndsWith(".json", StringComparison.Ordinal) || assetPath.Contains("..") ||
                assetPath.Contains("\\") || assetPath.Contains("//"))
                throw new ArgumentException("Use an Assets-relative JSON path.", nameof(assetPath));
            // DeleteAsset is recursive for folders, including ones named with a .json suffix.
            // Both setup and removal must reject them before touching settings or assets.
            if (Directory.Exists(assetPath) || AssetDatabase.IsValidFolder(assetPath))
                throw new ArgumentException("The generated JSON path must not be a directory.", nameof(assetPath));
        }

        /// <summary>Delete the generated file and empty parent folders, stopping at Assets.</summary>
        public static void Remove(string assetPath = AssetPath)
        {
            ValidatePath(assetPath);
            AssetDatabase.DeleteAsset(assetPath);
            // A failed write/import may leave files the AssetDatabase does not know about yet.
            if (File.Exists(assetPath)) File.Delete(assetPath);
            if (File.Exists(assetPath + ".meta")) File.Delete(assetPath + ".meta");
            var dir = Path.GetDirectoryName(assetPath);
            while (!string.IsNullOrEmpty(dir) && dir != "Assets" &&
                Directory.Exists(dir) && Directory.GetFileSystemEntries(dir).Length == 0)
            {
                if (!AssetDatabase.DeleteAsset(dir)) Directory.Delete(dir);
                if (File.Exists(dir + ".meta")) File.Delete(dir + ".meta");
                dir = Path.GetDirectoryName(dir);
            }
        }

        static string RunGit(string args)
        {
            try
            {
                var psi = new ProcessStartInfo("git", args)
                {
                    WorkingDirectory = Directory.GetCurrentDirectory(),
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                };
                return RunProcess(psi, 30000);
            }
            catch (Exception e)
            {
                Debug.LogWarning("[BuildStamp] git " + args.Split(' ')[0] + ": " + e.Message);
                return null;
            }
        }

        // One deadline covers exit AND both redirected streams (which may outlive the process).
        static string RunProcess(ProcessStartInfo psi, int timeoutMilliseconds)
        {
            var clock = Stopwatch.StartNew();
            using (var p = Process.Start(psi))
            {
                try
                {
                    var stdout = p.StandardOutput.ReadToEndAsync();
                    var stderr = p.StandardError.ReadToEndAsync();
                    int Remaining() => (int)Math.Max(0, timeoutMilliseconds - clock.ElapsedMilliseconds);
                    if (!p.WaitForExit(Remaining()) || !Task.WaitAll(new Task[] { stdout, stderr }, Remaining()))
                        return null;
                    return p.ExitCode == 0 ? stdout.Result : null;
                }
                finally
                {
                    if (!p.HasExited)
                        try { p.Kill(); } catch (InvalidOperationException) { }
                }
            }
        }

        sealed class Undo : IDisposable
        {
            Action undo;
            public Undo(Action undo) => this.undo = undo;
            public void Dispose()
            {
                undo?.Invoke();
                undo = null;
            }
        }
    }
}
