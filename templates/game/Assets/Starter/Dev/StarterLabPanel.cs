using UnityEngine;
using UnityEngine.Events;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.UI;
using UnityEngine.UI;

namespace Game.Dev
{
    // Desktop controls only. XR wrist input is not routed to this canvas.
    public sealed class StarterLabPanel : MonoBehaviour
    {
        StarterLab lab;
        RectTransform card;
        Text compact, wide, status;
        GameObject tuning;
        Button decrease, increase, reset;
        Font font;

        internal static void Build(StarterLab lab)
        {
            var panel = lab.gameObject.AddComponent<StarterLabPanel>();
            panel.lab = lab;
            panel.CreateControls();
        }

        void CreateControls()
        {
            font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            var canvas = Item("Starter Lab Canvas", transform).gameObject.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvas.gameObject.AddComponent<GraphicRaycaster>();
            if (!EventSystem.current)
            {
                var input = new GameObject("Starter Lab Input");
                input.transform.SetParent(transform, false);
                input.AddComponent<EventSystem>();
                input.AddComponent<InputSystemUIInputModule>();
            }

            card = Item("Starter Lab", canvas.transform);
            Place(card, 16, 16, 304, 230);
            card.gameObject.AddComponent<Image>().color = new Color(0.07f, 0.10f, 0.13f, 0.95f);
            Label(card, "Starter Lab  |  F8 to toggle", 12, 6, 280, 28);
            Label(card, "Choose a snap-turn experiment", 12, 35, 280, 24);
            compact = Button(card, "Compact turn", 12, 65, 136, () => lab.Select(StarterLab.Compact)).GetComponentInChildren<Text>();
            wide = Button(card, "Wide turn", 156, 65, 136, () => lab.Select(StarterLab.Wide)).GetComponentInChildren<Text>();
            var controls = Item("Tuning", card);
            Place(controls, 0, 104, 304, 126);
            tuning = controls.gameObject;
            status = Label(controls, "Tuning status", 12, 4, 280, 58);
            decrease = Button(controls, "−5°", 12, 69, 80, () => Step(-1));
            increase = Button(controls, "+5°", 102, 69, 80, () => Step(1));
            reset = Button(controls, "Reset", 192, 69, 100, lab.ResetAngle);
            Refresh();
        }

        void Step(int direction)
        {
            if (lab.Angle is { } angle) angle.Set(angle.Get() + direction * angle.Step);
        }

        void Update()
        {
            if (Keyboard.current?.f8Key.wasPressedThisFrame == true) card.gameObject.SetActive(!card.gameObject.activeSelf);
            Refresh();
        }

        void Refresh()
        {
            compact.text = "Compact turn" + Suffix(StarterLab.Compact);
            wide.text = "Wide turn" + Suffix(StarterLab.Wide);
            var selected = lab.CurrentId != null;
            tuning.SetActive(selected);
            if (!selected) return;
            var angle = lab.Angle;
            decrease.interactable = increase.interactable = reset.interactable = angle != null;
            status.text = angle != null
                ? $"Snap turn: {angle.Get():0}° ({(lab.HasOverride ? "override" : "default")})\n" +
                    $"Experiment default: {angle.Default:0}°"
                : $"Snap turn: {lab.SnapAngle:0}° (default)\nPersistence unavailable\nUnreadable saved tuning was kept.";
        }

        string Suffix(string id) => lab.CurrentId == id ? " (active)" : lab.SuggestedId == id ? " (last)" : "";

        Button Button(Transform parent, string caption, float x, float y, float width, UnityAction click)
        {
            var rect = Item(caption, parent);
            Place(rect, x, y, width, 34);
            var image = rect.gameObject.AddComponent<Image>();
            image.color = new Color(0.21f, 0.30f, 0.36f);
            var button = rect.gameObject.AddComponent<Button>();
            button.targetGraphic = image;
            button.navigation = new Navigation { mode = Navigation.Mode.None };
            button.onClick.AddListener(click);
            var text = Label(rect, caption, 0, 0, width, 34);
            text.alignment = TextAnchor.MiddleCenter;
            return button;
        }

        Text Label(Transform parent, string caption, float x, float y, float width, float height)
        {
            var rect = Item(caption, parent);
            Place(rect, x, y, width, height);
            var text = rect.gameObject.AddComponent<Text>();
            text.font = font;
            text.fontSize = 15;
            text.color = Color.white;
            text.alignment = TextAnchor.MiddleLeft;
            text.raycastTarget = false;
            text.text = caption;
            return text;
        }

        static RectTransform Item(string name, Transform parent)
        {
            var item = (RectTransform)new GameObject(name, typeof(RectTransform)).transform;
            item.SetParent(parent, false);
            return item;
        }

        static void Place(RectTransform rect, float x, float y, float width, float height)
        {
            rect.anchorMin = rect.anchorMax = rect.pivot = Vector2.up;
            rect.anchoredPosition = new Vector2(x, -y);
            rect.sizeDelta = new Vector2(width, height);
        }
    }
}
