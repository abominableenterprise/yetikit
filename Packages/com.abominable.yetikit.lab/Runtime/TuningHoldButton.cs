using System;
using UnityEngine;
using UnityEngine.EventSystems;

namespace YetiKit.Lab
{
    /// <summary>Single-pointer press and repeat adapter for a world-space Unity UI canvas.</summary>
    public sealed class TuningHoldButton : MonoBehaviour, IPointerDownHandler, IPointerUpHandler, IPointerExitHandler
    {
        readonly TuningRepeat repeat = new();
        int? pointer;
        public event Action Step;

        public void OnPointerDown(PointerEventData data)
        {
            if (pointer.HasValue || data.button != PointerEventData.InputButton.Left) return;
            pointer = data.pointerId;
            repeat.Begin(Time.unscaledTime);
            Step?.Invoke();
        }

        public void OnPointerUp(PointerEventData data) { if (pointer == data.pointerId) Cancel(); }
        public void OnPointerExit(PointerEventData data) { if (pointer == data.pointerId) Cancel(); }
        void OnDisable() => Cancel();
        void OnApplicationFocus(bool focused) { if (!focused) Cancel(); }
        void OnApplicationPause(bool paused) { if (paused) Cancel(); }
        void Update() { if (repeat.Tick(pointer.HasValue, Time.unscaledTime)) Step?.Invoke(); }

        internal void Cancel()
        {
            pointer = null;
            repeat.Cancel();
        }
    }
}
