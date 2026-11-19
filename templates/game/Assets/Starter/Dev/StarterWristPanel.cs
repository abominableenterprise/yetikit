using System.Linq;
using Game.Starter;
using UnityEngine;
using UnityEngine.UI;
using YetiKit.Hands;

namespace Game.Dev
{
    // Use the position drawn last frame for both the kit's hand UI guard and our hit test.
    // Route controller input and hand hover before the interaction manager processes selections.
    [DefaultExecutionOrder(PlayerHand.ExecutionOrder + 2)]
    public sealed class StarterWristPanel : MonoBehaviour
    {
        const float UnitsPerPixel = 0.001f;
        const float PokeDepth = 0.018f;
        const float PointerReach = 1.5f;
        PlayerHand wearer, pointer;
        ControllerTracking controller;
        Camera head;
        Canvas canvas;
        StarterLabPanel controls;
        LineRenderer beam;
        Button[] buttons;
        Button pressed, highlighted;
        RectTransform registeredCard;
        bool triggerWasDown, pokeArmed, handCapture;
        int pointerEpoch = -1, wearerEpoch = -1;

        internal static void Build(StarterLab lab, Transform rig)
        {
            var hands = rig.GetComponentsInChildren<PlayerHand>();
            var left = hands.FirstOrDefault(hand => !hand.RightHand);
            var right = hands.FirstOrDefault(hand => hand.RightHand);
            var camera = rig.GetComponentInChildren<Camera>();
            if (!left || !right || !camera || !right.TryGetComponent<ControllerTracking>(out var tracking)) return;

            var root = new GameObject("Starter Lab Wrist");
            root.transform.SetParent(lab.transform, false);
            var panel = root.AddComponent<StarterWristPanel>();
            panel.wearer = left;
            panel.pointer = right;
            panel.controller = tracking;
            panel.head = camera;
            panel.canvas = new GameObject("Wrist Canvas", typeof(RectTransform), typeof(Canvas)).GetComponent<Canvas>();
            var rect = (RectTransform)panel.canvas.transform;
            rect.SetParent(root.transform, false);
            rect.localScale = Vector3.one * UnitsPerPixel;
            panel.canvas.renderMode = RenderMode.WorldSpace;
            panel.canvas.worldCamera = camera;
            panel.controls = rect.gameObject.AddComponent<StarterLabPanel>();
            panel.controls.CreateControls(lab, panel.canvas, false);
            rect.sizeDelta = panel.controls.Card.sizeDelta;
            panel.buttons = rect.GetComponentsInChildren<Button>(true);
            panel.canvas.gameObject.SetActive(false);

            panel.beam = root.AddComponent<LineRenderer>();
            panel.beam.sharedMaterial = right.GetComponent<HandTeleport>().line.sharedMaterial;
            panel.beam.widthMultiplier = 0.003f;
            panel.beam.positionCount = 2;
            panel.beam.enabled = false;
            panel.registeredCard = panel.controls.Card;
            HandUiGuard.Rects.Add(panel.registeredCard);
        }

        void LateUpdate()
        {
            var shown = wearer.isActiveAndEnabled && wearer.Present;
            canvas.gameObject.SetActive(shown);
            if (!shown) return;
            var wrist = wearer.Mode == HandMode.Controller ? wearer.controller.position : wearer.WristPose.position;
            var offset = head.transform.up * 0.17f + head.transform.forward * 0.055f;
            canvas.transform.SetPositionAndRotation(wrist + offset,
                Quaternion.LookRotation(wrist + offset - head.transform.position, head.transform.up));
        }

        void Update()
        {
            controls.Refresh();
            var visible = canvas.gameObject.activeSelf && wearer.isActiveAndEnabled && wearer.Present;
            if (pointerEpoch != pointer.PoseEpoch || wearerEpoch != wearer.PoseEpoch || !visible)
            {
                pressed = null;
                pokeArmed = false;
                triggerWasDown = controller.TriggerPressed;
                pointerEpoch = pointer.PoseEpoch;
                wearerEpoch = wearer.PoseEpoch;
            }

            var overUi = false;
            Button hover = null;
            if (visible && pointer.Mode == HandMode.Controller && !controller.HoldingProp)
            {
                var start = pointer.controller.position;
                overUi = HitsCard(new Ray(start, pointer.controller.forward), out var hit);
                if (overUi)
                {
                    beam.SetPosition(0, start);
                    beam.SetPosition(1, hit);
                    hover = ButtonAt(hit);
                }
                if (controller.TriggerPressed && !triggerWasDown) pressed = hover;
                if (pressed != hover) pressed = null;
                if (!controller.TriggerPressed && triggerWasDown)
                {
                    Activate(pressed);
                    pressed = null;
                }
            }
            else pressed = null;
            triggerWasDown = controller.TriggerPressed;
            controller.RoutePointer(overUi);
            beam.enabled = overUi;

            var nearCard = visible && pointer.HandTracked && !HandTeleport.Holding(pointer) &&
                HandUiGuard.Distance(controls.Card, pointer.Joint(PinchStrength.IndexTip)) <= TeleportAim.UiReach;
            // Crossing the UI boundary while still pinching must not turn a press into a room grab.
            handCapture = nearCard || (handCapture && pointer.Grab.Selecting);
            pointer.FarInteraction.Hover(this, pointer.HandTracked && handCapture);
            if (visible && pointer.TryIndexTip(out var tip) && !HandTeleport.Holding(pointer))
            {
                var card = controls.Card;
                // The canvas faces the user along -forward. Only withdrawal on that side rearms,
                // even when the fingertip leaves the guard's unsigned reach.
                var frontDepth = Vector3.Dot(tip - card.position, -card.forward);
                if (frontDepth > PokeDepth + HandPoke.ExitMargin) pokeArmed = true;
                else if (nearCard && HandUiGuard.Distance(card, tip) <= PokeDepth)
                {
                    hover = ButtonAt(tip);
                    if (pokeArmed) Activate(hover);
                    pokeArmed = false;
                }
                else if (frontDepth <= 0f) pokeArmed = false; // A fast poke can skip the contact band.
            }
            else pokeArmed = false;
            Highlight(hover);
        }

        bool HitsCard(Ray ray, out Vector3 hit)
        {
            var card = controls.Card;
            hit = default;
            if (!new Plane(-card.forward, card.position).Raycast(ray, out var distance) || distance > PointerReach ||
                Vector3.Dot(card.forward, ray.direction) <= 0f) return false;
            hit = ray.GetPoint(distance);
            return card.rect.Contains(card.InverseTransformPoint(hit));
        }

        Button ButtonAt(Vector3 point)
        {
            foreach (var button in buttons)
            {
                if (!button.isActiveAndEnabled || !button.IsInteractable()) continue;
                var rect = (RectTransform)button.transform;
                if (rect.rect.Contains(rect.InverseTransformPoint(point))) return button;
            }
            return null;
        }

        static void Activate(Button button)
        {
            if (button && button.isActiveAndEnabled && button.IsInteractable()) button.onClick.Invoke();
        }

        void Highlight(Button hover)
        {
            if (highlighted == hover) return;
            if (highlighted) highlighted.image.color = new Color(0.21f, 0.30f, 0.36f);
            highlighted = hover;
            if (highlighted) highlighted.image.color = new Color(0.22f, 0.49f, 0.57f);
        }

        void OnDisable()
        {
            if (canvas) canvas.gameObject.SetActive(false);
            if (beam) beam.enabled = false;
            if (controller) controller.RoutePointer(false);
            if (pointer) pointer.FarInteraction.Hover(this, false);
            pressed = null;
            pokeArmed = handCapture = false;
            Highlight(null);
        }

        void OnDestroy() => HandUiGuard.Rects.Remove(registeredCard);
    }
}
