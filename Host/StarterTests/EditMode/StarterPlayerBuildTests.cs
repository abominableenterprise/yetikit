using System;
using System.Collections;
using System.IO;
using System.Linq;
using Game.Starter.Editor;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using YetiKit.Quality.Editor;

namespace YetiKit.Starter.HostTests
{
    [Category("Gfx")]
    public sealed class StarterPlayerBuildTests
    {
        [Test]
        public void ReleaseAuditRejectsSyntheticDevControl()
        {
            // Model a release input that leaked the assembly containing the photo and other Lab controls.
            var assembly = typeof(Game.Dev.StarterLab).Assembly.GetName().Name;
            var paths = new[] { "Library/PlayerScriptAssemblies/Game.Starter.dll", $"Library/PlayerScriptAssemblies/{assembly}.dll" };
            var hook = new BuildAuditHook();
            BuildAuditHook.Enable(new BuildAuditRules());
            try
            {
                Assert.That(hook.OnFilterAssemblies(BuildOptions.Development, paths), Is.SameAs(paths));
                var error = Assert.Throws<BuildFailedException>(() => hook.OnFilterAssemblies(BuildOptions.None, paths));
                Assert.That(error.Message, Is.EqualTo("Forbidden assembly: Game.Dev"));
            }
            finally { BuildAuditHook.Disable(); }
        }

        [UnityTest]
        public IEnumerator DesktopPlayersKeepDevControlsOnlyInDevelopment()
        {
            const BuildTarget target = BuildTarget.StandaloneLinux64;
            if (EditorUserBuildSettings.activeBuildTarget != target)
                Assert.Ignore("Run in the Linux desktop Host.");
            Assert.That(BuildPipeline.IsBuildTargetSupported(BuildTargetGroup.Standalone, target), Is.True);
            if (StarterControllerSample.Import()) yield return new RecompileScripts();

            var assetRoot = "Assets/StarterTests/PlayerBuild-" + Guid.NewGuid().ToString("N");
            var output = Path.GetFullPath(Path.Combine("build", Path.GetFileName(assetRoot)));
            var previousScenes = EditorSceneManager.GetSceneManagerSetup();
            Directory.CreateDirectory(assetRoot);
            try
            {
                AssetDatabase.Refresh();
                var baseline = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                Assert.That(EditorSceneManager.SaveScene(baseline, assetRoot + "/Baseline.unity"), Is.True);
                var scene = SandboxBuilder.Build(assetRoot + "/Sandbox");
                foreach (var development in new[] { false, true })
                {
                    var folder = Path.Combine(output, development ? "dev" : "release");
                    Directory.CreateDirectory(folder);
                    var report = StarterPlayerBuild.Build(new BuildPlayerOptions
                    {
                        target = target,
                        scenes = new[] { scene },
                        options = development ? BuildOptions.Development : BuildOptions.None,
                        // A stale per-build define must not leak Lab or Playtest into release.
                        extraScriptingDefines = development ? null : new[] { "YETIKIT_DEV" },
                        locationPathName = Path.Combine(folder, "Sandbox.x86_64")
                    });
                    Assert.That(report.summary.result, Is.EqualTo(BuildResult.Succeeded));
                    var managed = Path.Combine(folder, "Sandbox_Data", "Managed");
                    var assemblies = Directory.GetFiles(managed, "*.dll").Select(Path.GetFileNameWithoutExtension).ToArray();
                    Assert.That(assemblies, Does.Contain("Game.Starter"));
                    Assert.That(assemblies.Contains("Game.Dev"), Is.EqualTo(development), "Dev controls in the shipped player");
                    // The ASCII type name lives in the managed metadata, independent of the log string.
                    var diagnostic = nameof(Game.Dev.StarterAimDiagnostic);
                    Assert.That(Directory.EnumerateFiles(managed, "*.dll").Any(dll =>
                        System.Text.Encoding.ASCII.GetString(File.ReadAllBytes(dll)).Contains(diagnostic)),
                        Is.EqualTo(development), "Starter aim diagnostic in the shipped player");
                    if (!development)
                    {
                        var rules = new BuildAuditRules();
                        Assert.That(BuildAudit.Check(report, rules), Is.Empty);
                        Assert.That(BuildAudit.Check(assemblies, Array.Empty<string>(), rules), Is.Empty);
                        Assert.That(assemblies, Does.Not.Contain("YetiKit.Playtest"));
                    }
                    else
                    {
                        Assert.That(assemblies, Does.Contain("YetiKit.Lab"));
                        Assert.That(assemblies, Does.Contain("YetiKit.Playtest"));
                    }
                }
            }
            finally
            {
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                AssetDatabase.DeleteAsset(assetRoot);
                if (previousScenes.Length > 0 && previousScenes.All(scene => !string.IsNullOrEmpty(scene.path)))
                    EditorSceneManager.RestoreSceneManagerSetup(previousScenes);
                if (Directory.Exists(output)) Directory.Delete(output, true);
            }
        }
    }
}
