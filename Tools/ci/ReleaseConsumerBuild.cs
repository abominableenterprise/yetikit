using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;

public static class ReleaseConsumerBuild
{
    public static void DevelopmentApk()
    {
        const string scene = "Assets/Consumer.unity";
        const string apk = "Builds/Android/consumer.apk";
        if (!EditorSceneManager.SaveScene(EditorSceneManager.NewScene(NewSceneSetup.EmptyScene), scene))
            throw new InvalidOperationException("Could not save the consumer scene.");

        Directory.CreateDirectory(Path.GetDirectoryName(apk));
        var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
        {
            scenes = new[] { scene },
            locationPathName = apk,
            target = BuildTarget.Android,
            options = BuildOptions.Development,
            extraScriptingDefines = new[] { "YETIKIT_DEV" },
        });
        if (report.summary.result != BuildResult.Succeeded)
            throw new InvalidOperationException($"Consumer Android build: {report.summary.result}");
    }
}
