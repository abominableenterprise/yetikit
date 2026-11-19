using System;
using System.Collections;
using System.Linq;
using Game.Dev;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.UI;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;
using YetiKit.Lab;

namespace YetiKit.Starter.HostTests
{
    static class StarterLabChecks
    {
        static readonly string[] PrefKeys = {
            "YetiKit.Lab.Selection.starter-sandbox",
            "YetiKit.Lab.Tuning.starter-sandbox.snap-30",
            "YetiKit.Lab.Tuning.starter-sandbox.snap-45"
        };
        const string BackupKey = "StarterLabChecks.Backup";
        const string Missing = "\u0001";

        public static void AssertSavedScene(Scene scene)
        {
            Assert.That(scene.GetRootGameObjects().SelectMany(go => go.GetComponentsInChildren<MonoBehaviour>(true))
                .Any(component => component && component.GetType().Assembly == typeof(StarterLab).Assembly), Is.False,
                "The saved room must not depend on dev controls.");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(30f));
            Assert.That(StarterLab.TryDirectBoot(new[] { "--starter-experiment", "invalid" }, scene.path,
                _ => Assert.Fail("Invalid IDs must not load a scene.")), Is.False);
            Assert.That(StarterLab.TryDirectBoot(new[] { "--starter-experiment" }, scene.path,
                _ => Assert.Fail("Missing IDs must not load a scene.")), Is.False);
        }

        public static IEnumerator DriveAndReload(string path)
        {
            BackupPrefs();
            var scene = Load(path);
            yield return null;
            var lab = Lab(scene);
            Assert.That(lab.CurrentId, Is.Null);
            Assert.That(Panel(lab).GetComponentsInChildren<Button>().Select(button => button.name),
                Is.EquivalentTo(new[] { "Compact turn", "Wide turn" }));
            Capture("Start");
            yield return null;

            Click(lab, "Compact turn");
            Assert.That(lab.CurrentId, Is.EqualTo(StarterLab.Compact));
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(30f));
            yield return null;
            Click(lab, "+5°");
            Click(lab, "+5°");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(40f));
            yield return null;
            Assert.That(Status(lab), Does.Contain("40° (override)").And.Contain("default: 30°"));
            Capture("Override");
            yield return null;

            Click(lab, "Wide turn");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(45f), "The other experiment has its own default.");
            yield return null;
            Click(lab, "−5°");
            Assert.That(StarterLab.TryDirectBoot(new[] { "--starter-experiment", StarterLab.Compact }, path,
                target => scene = Load(target)), Is.True);
            yield return null;
            lab = Lab(scene);
            Assert.That(lab.CurrentId, Is.EqualTo(StarterLab.Compact));
            Assert.That(lab.SuggestedId, Is.EqualTo(StarterLab.Wide), "Direct boot must not save the selection.");
            Assert.That(DevBoot.Consume(path), Is.Null, "Direct selection is one-shot.");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(40f), "A fresh model restores the selected experiment's value.");
            Click(lab, "Reset");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(30f));
            yield return null;
            Assert.That(Status(lab), Does.Contain("30° (default)"));

            scene = Load(path);
            yield return null;
            lab = Lab(scene);
            Assert.That(lab.CurrentId, Is.Null);
            Click(lab, "Wide turn");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(40f), "Unload saved the last edit to the other experiment.");
            Click(lab, "Compact turn");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(30f), "Reset survived model recreation.");
        }

        static Scene Load(string path) => EditorSceneManager.LoadSceneInPlayMode(path, new LoadSceneParameters(LoadSceneMode.Single));
        static StarterLab Lab(Scene scene) => StarterSandboxTests.Root(scene, "Sandbox Bindings").GetComponent<StarterLab>();
        static StarterLabPanel Panel(StarterLab lab) => lab.GetComponent<StarterLabPanel>();
        static SnapTurnProvider Turn(Scene scene) => StarterSandboxTests.Root(scene, "XR Origin").GetComponent<SnapTurnProvider>();
        static string Status(StarterLab lab) => Panel(lab).GetComponentsInChildren<Text>()
            .Single(text => text.name == "Tuning status").text;
        static void Click(StarterLab lab, string name) => Panel(lab).GetComponentsInChildren<Button>()
            .Single(button => button.name == name).onClick.Invoke();

        static void Capture(string state)
        {
            var dir = Environment.GetEnvironmentVariable("YETIKIT_STARTER_LAB_CAPTURE");
            if (!string.IsNullOrEmpty(dir)) ScreenCapture.CaptureScreenshot(System.IO.Path.Combine(dir, state + ".png"));
        }

        static void BackupPrefs()
        {
            SessionState.SetBool(BackupKey, true);
            foreach (var key in PrefKeys)
            {
                SessionState.SetString(key, PlayerPrefs.GetString(key, Missing));
                PlayerPrefs.DeleteKey(key);
            }
        }

        public static void RestorePrefs()
        {
            if (!SessionState.GetBool(BackupKey, false)) return;
            foreach (var key in PrefKeys)
            {
                var value = SessionState.GetString(key, Missing);
                if (value == Missing) PlayerPrefs.DeleteKey(key);
                else PlayerPrefs.SetString(key, value);
                SessionState.EraseString(key);
            }
            PlayerPrefs.Save();
            SessionState.EraseBool(BackupKey);
        }
    }
}
