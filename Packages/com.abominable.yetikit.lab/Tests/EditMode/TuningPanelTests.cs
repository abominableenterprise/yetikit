using System.IO;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.UI;

namespace YetiKit.Lab.Tests
{
    public sealed class TuningPanelTests
    {
        [Test]
        public void HoldWaitsThenRepeatsWithoutCatchUpAndStopsOnRelease()
        {
            var repeat = new TuningRepeat();
            repeat.Begin(0);
            Assert.That(repeat.Tick(true, .39f), Is.False);
            Assert.That(repeat.Tick(true, .4f), Is.True);
            Assert.That(repeat.Tick(true, 2), Is.True);
            Assert.That(repeat.Tick(true, 2), Is.False);
            Assert.That(repeat.Tick(false, 3), Is.False);
            Assert.That(repeat.Tick(true, 4), Is.False);
        }

        [Test, Category("Gfx")]
        public void WorldSpacePanelPagesAdjustsAndResets()
        {
            var root = new GameObject("Synthetic panel", typeof(RectTransform), typeof(Canvas), typeof(Image));
            var cameraObject = new GameObject("Synthetic camera", typeof(Camera));
            var camera = cameraObject.GetComponent<Camera>();
            var target = new RenderTexture(640, 360, 24);
            try
            {
                var canvas = root.GetComponent<Canvas>();
                canvas.renderMode = RenderMode.WorldSpace;
                ((RectTransform)root.transform).sizeDelta = new Vector2(560, 280);
                root.GetComponent<Image>().color = new Color(.11f, .17f, .23f);
                camera.transform.position = new Vector3(0, 0, -10);
                camera.orthographic = true;
                camera.orthographicSize = 180;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(.04f, .07f, .09f);
                camera.targetTexture = target;
                canvas.worldCamera = camera;

                var label = Label(root.transform, "", 0, 65, 420, 110, 32);
                var previous = Control<Button>(root.transform, "Previous", -168, -90);
                var next = Control<Button>(root.transform, "Next", 168, -90);
                var reset = Control<Button>(root.transform, "Reset", 0, -90);
                var minus = Control<TuningHoldButton>(root.transform, "−", -84, -24);
                var plus = Control<TuningHoldButton>(root.transform, "+", 84, -24);
                root.SetActive(false);
                var panel = root.AddComponent<TuningPanel>();
                var config = new SerializedObject(panel);
                config.FindProperty("label").objectReferenceValue = label;
                config.FindProperty("previous").objectReferenceValue = previous;
                config.FindProperty("next").objectReferenceValue = next;
                config.FindProperty("reset").objectReferenceValue = reset;
                config.FindProperty("minus").objectReferenceValue = minus;
                config.FindProperty("plus").objectReferenceValue = plus;
                config.ApplyModifiedPropertiesWithoutUndo();
                root.SetActive(true);
                // Invoke lifecycle explicitly: this EditMode fixture does not enter Play Mode.
                typeof(TuningPanel).GetMethod("OnEnable", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(panel, null);
                var tuning = new Tuning("panel-fixture", new EmptyStore());
                float gain = 1;
                bool preview = false;
                tuning.Float("Gain", () => gain, value => gain = value, 1, 0, 2, .25f);
                tuning.Bool("Preview", () => preview, value => preview = value, false);
                panel.Bind(tuning);
                Assert.That(label.text, Does.Contain("Gain  (1/2)"));
                Capture(camera, target);
                next.onClick.Invoke();
                Assert.That(label.text, Does.Contain("Preview  (2/2)"));
                var pointer = new PointerEventData(null) { pointerId = 1 };
                plus.OnPointerDown(pointer);
                plus.OnPointerUp(pointer);
                Assert.That(preview, Is.True);
                reset.onClick.Invoke();
                Assert.That(preview, Is.False);
                next.onClick.Invoke();
                Assert.That(label.text, Does.Contain("Gain  (1/2)"));
            }
            finally
            {
                Object.DestroyImmediate(root);
                Object.DestroyImmediate(cameraObject);
                Object.DestroyImmediate(target);
            }
        }

        static Text Label(Transform parent, string text, float x, float y, float w, float h, int size)
        {
            var obj = new GameObject("Label", typeof(RectTransform), typeof(Text));
            var rect = (RectTransform)obj.transform;
            rect.SetParent(parent, false);
            rect.anchoredPosition = new Vector2(x, y);
            rect.sizeDelta = new Vector2(w, h);
            var label = obj.GetComponent<Text>();
            label.text = text;
            label.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            label.fontSize = size;
            label.color = Color.white;
            label.alignment = TextAnchor.MiddleCenter;
            return label;
        }

        static T Control<T>(Transform parent, string text, float x, float y) where T : Component
        {
            var obj = new GameObject("Control", typeof(RectTransform), typeof(Image), typeof(T));
            var rect = (RectTransform)obj.transform;
            rect.SetParent(parent, false);
            rect.anchoredPosition = new Vector2(x, y);
            rect.sizeDelta = new Vector2(142, 52);
            obj.GetComponent<Image>().color = new Color(.19f, .32f, .43f);
            Label(rect, text, 0, 0, 140, 50, 24).raycastTarget = false;
            return obj.GetComponent<T>();
        }

        static void Capture(Camera camera, RenderTexture target)
        {
            var output = System.Environment.GetEnvironmentVariable("YETIKIT_LAB_PANEL_CAPTURE");
            if (string.IsNullOrEmpty(output)) return;
            var active = RenderTexture.active;
            var image = new Texture2D(target.width, target.height, TextureFormat.RGB24, false);
            try
            {
                Canvas.ForceUpdateCanvases();
                camera.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0);
                image.Apply();
                File.WriteAllBytes(output, image.EncodeToPNG());
            }
            finally { RenderTexture.active = active; Object.DestroyImmediate(image); }
        }

        sealed class EmptyStore : ITuningStore
        {
            public string Load(string experimentId) => null;
            public void Save(string experimentId, string body) { }
        }
    }
}
