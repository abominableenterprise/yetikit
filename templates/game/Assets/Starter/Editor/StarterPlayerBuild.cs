using System;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using YetiKit.Quality.Editor;

namespace Game.Starter.Editor
{
    // Start here for both Build Profiles and scripted builds. Consumer build tooling can replace this handler.
    public static class StarterPlayerBuild
    {
        const string DevDefine = "YETIKIT_DEV";

        [InitializeOnLoadMethod]
        static void Register() => BuildPlayerWindow.RegisterBuildPlayerHandler(options => Build(options));

        public static BuildReport Build(BuildPlayerOptions options)
        {
            if (options.target != EditorUserBuildSettings.activeBuildTarget)
                throw new BuildFailedException("Switch to the desired Build Profile before building the starter.");
            if (options.scenes == null || options.scenes.Length == 0)
                throw new BuildFailedException("Add the baked sandbox to the build's scene list before building the starter.");

            var development = (options.options & BuildOptions.Development) != 0;
            var defines = (options.extraScriptingDefines ?? Array.Empty<string>()).Where(define => define != DevDefine);
            options.extraScriptingDefines = (development ? defines.Append(DevDefine) : defines).ToArray();
            if (!development)
            {
                // Do not ignore exceptions raised by post-build audit callbacks.
                options.options |= BuildOptions.StrictMode;
                BuildAuditHook.Enable(new BuildAuditRules());
            }
            try
            {
                var report = BuildPipeline.BuildPlayer(options);
                if (report == null || report.summary.result != BuildResult.Succeeded)
                    throw new BuildFailedException("Starter player build did not succeed. See the build log for details.");
                return report;
            }
            finally
            {
                if (!development) BuildAuditHook.Disable();
            }
        }
    }
}
