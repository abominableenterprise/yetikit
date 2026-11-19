using System.Globalization;
using UnityEngine;
using UnityEngine.UI;

namespace YetiKit.Lab
{
    /// <summary>One binding per page. Place on a world-space canvas with the rig's UI raycaster.</summary>
    public sealed class TuningPanel : MonoBehaviour
    {
        [SerializeField] Text label;
        [SerializeField] Button previous, next, reset;
        [SerializeField] TuningHoldButton minus, plus;
        Tuning tuning;
        int page;
        ITuningBinding Binding => tuning != null && tuning.Bindings.Count > 0 ? tuning.Bindings[page] : null;

        bool Wired => label && previous && next && reset && minus && plus;
        public void Bind(Tuning model) { tuning = model; Page(0); }

        void OnEnable()
        {
            if (!Wired) return;
            previous.onClick.AddListener(Previous); next.onClick.AddListener(Next); reset.onClick.AddListener(ResetBinding);
            minus.Step += Decrease; plus.Step += Increase;
            Refresh();
        }

        void OnDisable()
        {
            if (previous) previous.onClick.RemoveListener(Previous);
            if (next) next.onClick.RemoveListener(Next);
            if (reset) reset.onClick.RemoveListener(ResetBinding);
            if (minus) { minus.Step -= Decrease; minus.Cancel(); }
            if (plus) { plus.Step -= Increase; plus.Cancel(); }
        }

        void Update() => Refresh();
        void Previous() => Page(page - 1);
        void Next() => Page(page + 1);
        void Decrease() => Adjust(-1);
        void Increase() => Adjust(1);
        void Adjust(int direction) { if (Binding is { } b) b.Set(b.Get() + direction * b.Step); }
        void ResetBinding() { if (Binding is { } b) tuning.Reset(b.Id); }

        void Page(int index)
        {
            minus?.Cancel(); plus?.Cancel();
            var count = tuning?.Bindings.Count ?? 0;
            page = count == 0 ? 0 : (index + count) % count;
            Refresh();
        }
        void Refresh()
        {
            if (!Wired) return;
            var binding = Binding;
            label.text = binding == null ? "No tuning bindings" : $"{binding.Id}  ({page + 1}/{tuning.Bindings.Count})\n" +
                (binding.IsBool ? (binding.Get() == 0 ? "Off" : "On") : binding.Get().ToString("G4", CultureInfo.InvariantCulture));
            previous.interactable = next.interactable = (tuning?.Bindings.Count ?? 0) > 1;
            reset.interactable = binding != null;
        }
    }
}
