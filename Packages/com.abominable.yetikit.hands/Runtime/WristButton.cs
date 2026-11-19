using UnityEngine;
using UnityEngine.Events;

namespace YetiKit.Hands
{
    /// <summary>A wrist-mounted button pressed by the other hand's straight index finger.</summary>
    public sealed class WristButton : MonoBehaviour
    {
        public const float Radius = 0.02f, Cooldown = 0.8f;

        [Tooltip("The hand wearing the button.")]
        public PlayerHand wearer;
        [Tooltip("The hand whose index finger presses the button.")]
        public PlayerHand presser;
        [Tooltip("Optional visual shown while the wearer is tracked.")]
        public GameObject visual;
        [Tooltip("Called when a new press is accepted.")]
        public UnityEvent onPressed = new UnityEvent();
        public event System.Action Pressed;

        readonly HandPoke poke = new HandPoke(Cooldown);

        public bool Shown => wearer && wearer.isActiveAndEnabled && wearer.HandTracked;

        void Update() => Tick(Time.time);
        void OnDisable()
        {
            poke.Release();
            if (visual && visual != gameObject) visual.SetActive(false);
        }

        /// <summary>Sample one frame after the hands update. True only on a new press.</summary>
        public bool Tick(float now)
        {
            if (!isActiveAndEnabled) return false;
            var shown = Shown;
            if (visual && visual != gameObject && visual.activeSelf != shown) visual.SetActive(shown);
            if (!shown || !presser || !presser.isActiveAndEnabled || !presser.TryIndexTip(out var tip))
            {
                poke.Release();
                return false;
            }
            if (!poke.Tick(Vector3.Distance(tip, transform.position), Radius, now)) return false;
            Pressed?.Invoke();
            onPressed?.Invoke();
            return true;
        }
    }
}
