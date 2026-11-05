using UnityEditor.Build;
using UnityEditor.Build.Reporting;

namespace YetiKit.Quality.Editor
{
    /// <summary>Opt in from the consumer's build entry point, immediately before BuildPipeline.BuildPlayer.</summary>
    public sealed class BuildAuditHook : IPostprocessBuildWithReport, IFilterBuildAssemblies
    {
        static BuildAuditRules enabledRules;
        public int callbackOrder => int.MaxValue;
        public static void Enable(BuildAuditRules rules) => enabledRules = rules ?? throw new System.ArgumentNullException(nameof(rules));
        public static void Disable() => enabledRules = null;

        // This callback sees selected player assemblies before IL2CPP removes the DLL files.
        public string[] OnFilterAssemblies(UnityEditor.BuildOptions options, string[] assemblies)
        {
            if (enabledRules != null && (options & UnityEditor.BuildOptions.Development) == 0)
            {
                var violations = BuildAudit.Check(System.Array.ConvertAll(assemblies, System.IO.Path.GetFileNameWithoutExtension),
                    System.Array.Empty<string>(), enabledRules);
                if (violations.Count > 0) throw new BuildFailedException(string.Join("\n", violations));
            }
            return assemblies;
        }

        public void OnPostprocessBuild(BuildReport report)
        {
            if (enabledRules == null || (report.summary.options & UnityEditor.BuildOptions.Development) != 0) return;
            var violations = BuildAudit.Check(report, enabledRules);
            if (violations.Count > 0) throw new BuildFailedException(string.Join("\n", violations));
        }
    }
}
