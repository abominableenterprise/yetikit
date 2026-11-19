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
        internal const string CompactKey = "YetiKit.Lab.Tuning.starter-sandbox.snap-30";
        static readonly string[] PrefKeys = {
            "YetiKit.Lab.Selection.starter-sandbox",
            CompactKey,
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
            Capture(scene, lab, "Start");
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
            using (var photo = new StarterPhotoChecks(lab))
            {
                Click(lab, "Photo snap");
                photo.AssertLocalSnap(lab, StarterLab.Compact, 40f, 30f, hasOverride: true);
                yield return null;
                Assert.That(PhotoStatus(lab), Is.EqualTo("Photo saved locally."));
                Capture(scene, lab, "Override");
                yield return null;
                photo.AssertDestinationErrors(lab, () => Click(lab, "Photo snap"));
                yield return null;
                Assert.That(PhotoStatus(lab), Is.EqualTo("Could not write photo."));
            }

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

        public static IEnumerator DriveUnreadable(string path, string document, string fixture)
        {
            BackupPrefs();
            PlayerPrefs.SetString(CompactKey, document);
            PlayerPrefs.Save();
            var scene = Load(path);
            yield return null;
            var lab = Lab(scene);
            Click(lab, "Compact turn");
            yield return null;
            Capture(scene, lab, fixture);
            AssertUnreadable(scene, lab);
            using (var photo = new StarterPhotoChecks(lab))
            {
                Click(lab, "Photo snap");
                photo.AssertLocalSnap(lab, StarterLab.Compact, 30f, 30f, hasOverride: false, canPersist: false);
            }

            Click(lab, "Wide turn");
            yield return null;
            Assert.That(Button(lab, "+5°").interactable, Is.True, "A different experiment remains editable.");
            Click(lab, "+5°");
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(50f));
            Click(lab, "Compact turn");
            yield return null;
            AssertUnreadable(scene, lab);
            Assert.That(PlayerPrefs.GetString(CompactKey, Missing), Is.EqualTo(document), "Switching must not rewrite the saved data.");

            scene = Load(path);
            yield return null;
            lab = Lab(scene);
            Click(lab, "Compact turn");
            yield return null;
            AssertUnreadable(scene, lab);
            Assert.That(PlayerPrefs.GetString(CompactKey, Missing), Is.EqualTo(document), "Reloading must not rewrite the saved data.");
        }

        static void AssertUnreadable(Scene scene, StarterLab lab)
        {
            Assert.That(Turn(scene).turnAmount, Is.EqualTo(30f));
            var enabled = new[] { "−5°", "+5°", "Reset" }.Where(name => Button(lab, name).interactable).ToArray();
            var status = Status(lab);
            // Calling the callbacks directly should not bypass the read-only state.
            Click(lab, "+5°");
            var editedAngle = Turn(scene).turnAmount;
            Click(lab, "Reset");
            var resetAngle = Turn(scene).turnAmount;
            Assert.That(editedAngle, Is.EqualTo(30f),
                $"An unsavable override was applied; Reset returned to {resetAngle}°. Enabled controls: {string.Join(", ", enabled)}. Status: {status}");
            Assert.That(enabled, Is.Empty);
            Assert.That(status, Does.Contain("30° (default)").And.Contain("Persistence unavailable"));
            Assert.That(resetAngle, Is.EqualTo(30f));
        }

        internal static Scene Load(string path) => EditorSceneManager.LoadSceneInPlayMode(path, new LoadSceneParameters(LoadSceneMode.Single));
        static StarterLab Lab(Scene scene) => StarterSandboxTests.Root(scene, "Sandbox Bindings").GetComponent<StarterLab>();
        static StarterLabPanel Panel(StarterLab lab) => lab.GetComponent<StarterLabPanel>();
        static SnapTurnProvider Turn(Scene scene) => StarterSandboxTests.Root(scene, "XR Origin").GetComponent<SnapTurnProvider>();
        static string Status(StarterLab lab) => Panel(lab).GetComponentsInChildren<Text>()
            .Single(text => text.name == "Tuning status").text;
        static string PhotoStatus(StarterLab lab) => Panel(lab).GetComponentsInChildren<Text>()
            .Single(text => text.name == "Photo status").text;
        static Button Button(StarterLab lab, string name) => Panel(lab).GetComponentsInChildren<Button>()
            .Single(button => button.name == name);
        static void Click(StarterLab lab, string name) => Button(lab, name).onClick.Invoke();

        static void Capture(Scene scene, StarterLab lab, string state)
        {
            var dir = Environment.GetEnvironmentVariable("YETIKIT_STARTER_LAB_CAPTURE");
            if (string.IsNullOrEmpty(dir)) return;
            var camera = StarterSandboxTests.Root(scene, "XR Origin").GetComponentInChildren<Camera>();
            var canvas = Panel(lab).GetComponentInChildren<Canvas>();
            var target = RenderTexture.GetTemporary(768, 480, 24);
            var image = new Texture2D(target.width, target.height, TextureFormat.RGB24, false);
            var prior = RenderTexture.active;
            try
            {
                camera.targetTexture = target;
                canvas.renderMode = RenderMode.ScreenSpaceCamera;
                canvas.worldCamera = camera;
                canvas.planeDistance = 0.5f;
                Canvas.ForceUpdateCanvases();
                camera.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0);
                image.Apply();
                System.IO.File.WriteAllBytes(System.IO.Path.Combine(dir, state + ".png"), image.EncodeToPNG());
            }
            finally
            {
                canvas.renderMode = RenderMode.ScreenSpaceOverlay;
                camera.targetTexture = null;
                RenderTexture.active = prior;
                RenderTexture.ReleaseTemporary(target);
                UnityEngine.Object.Destroy(image);
            }
        }

        internal static void BackupPrefs()
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
