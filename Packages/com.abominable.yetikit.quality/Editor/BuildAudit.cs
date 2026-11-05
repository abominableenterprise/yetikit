using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEditor.Build.Reporting;

namespace YetiKit.Quality.Editor
{
    public sealed class BuildAuditRules
    {
        public string[] forbiddenAssemblyPrefixes = { "YetiKit.Playtest", "YetiKit.Lab" };
        // Deny every permission not explicitly allowed by default. A narrower deny list is optional.
        public string[] forbiddenPermissions = { "*" };
        public string[] allowedPermissions = Array.Empty<string>();
    }

    public static class BuildAudit
    {
        // The synthetic seam uses exactly the same policy as the BuildReport adapter.
        public static List<string> Check(IEnumerable<string> assemblies, IEnumerable<string> permissions, BuildAuditRules rules)
        {
            if (rules == null) throw new ArgumentNullException(nameof(rules));
            var violations = new List<string>();
            foreach (var name in assemblies.Distinct())
                if (name.Split('.').Any(segment => string.Equals(segment, "Dev", StringComparison.OrdinalIgnoreCase)) ||
                    rules.forbiddenAssemblyPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
                    violations.Add("Forbidden assembly: " + name);
            foreach (var permission in permissions.Distinct())
                if (!rules.allowedPermissions.Contains(permission) &&
                    (rules.forbiddenPermissions.Contains("*") || rules.forbiddenPermissions.Contains(permission)))
                    violations.Add("Forbidden permission: " + permission);
            return violations;
        }

        public static List<string> Check(BuildReport report, BuildAuditRules rules)
        {
            if (report == null) throw new ArgumentNullException(nameof(report));
            // Include assembly source paths retained in packed assets, not just shipped files.
            // Use the hook's assembly filter as well for IL2CPP (final DLLs can be absent).
            var assemblies = report.GetFiles().Select(file => file.path)
                .Concat(report.packedAssets.SelectMany(pack => pack.contents).Select(asset => asset.sourceAssetPath))
                .Where(path => path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                .Select(Path.GetFileNameWithoutExtension);
            var violations = Check(assemblies, Array.Empty<string>(), rules);
            if (report.summary.platform != BuildTarget.Android) return violations;
            try { violations.AddRange(Check(Array.Empty<string>(), ReadPermissions(report.summary.outputPath), rules)); }
            catch (Exception error) { violations.Add("Cannot audit final Android manifest: " + error.Message); }
            return violations;
        }

        static IEnumerable<string> ReadPermissions(string output)
        {
            // Audit the packaged, merged manifest, not a source manifest that misses plugin permissions.
            // aapt2 understands the APK's binary XML. Unsupported outputs fail closed.
            if (!File.Exists(output) || !output.EndsWith(".apk", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("An APK is required; app bundles and exported Gradle projects are not supported.");
            var sdk = Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT");
            if (string.IsNullOrEmpty(sdk)) sdk = Environment.GetEnvironmentVariable("ANDROID_HOME");
            if (string.IsNullOrEmpty(sdk)) sdk = Path.Combine(EditorApplication.applicationContentsPath, "PlaybackEngines/AndroidPlayer/SDK");
            var tools = Path.Combine(sdk, "build-tools");
            var executable = Directory.EnumerateFiles(tools, "aapt2*", SearchOption.AllDirectories)
                .Where(path => Path.GetFileName(path) == "aapt2" || Path.GetFileName(path) == "aapt2.exe")
                .OrderByDescending(path => path, StringComparer.Ordinal).FirstOrDefault();
            if (executable == null) throw new FileNotFoundException("Android SDK aapt2 was not found.");
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            start.Arguments = "dump permissions \"" + output.Replace("\"", "\\\"") + "\"";
            using (var process = Process.Start(start))
            {
                var stdout = process.StandardOutput.ReadToEndAsync();
                var stderr = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(30000))
                {
                    process.Kill();
                    throw new InvalidOperationException("aapt2 timed out.");
                }
                if (process.ExitCode != 0) throw new InvalidOperationException("aapt2 failed: " + stderr.Result);
                return Regex.Matches(stdout.Result, @"uses-permission(?:-[^: ]+)?: name='([^']+)'")
                    .Cast<Match>().Select(match => match.Groups[1].Value).ToArray();
            }
        }
    }
}
