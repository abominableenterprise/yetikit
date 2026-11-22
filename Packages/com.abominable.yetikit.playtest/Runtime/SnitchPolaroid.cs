#if UNITY_EDITOR || YETIKIT_DEV
using UnityEngine;
namespace YetiKit.Playtest
{
    public interface ISnapFeedbackPolicy { bool AllowFeedback { get; } }
    public sealed class SnitchPolaroid : MonoBehaviour
    {
        readonly PolaroidCard card = new();
        ISnapFeedbackPolicy policy;
        MeshRenderer quad;
        RenderTexture image;
        Material material;
        AudioSource audioSource;
        Transform head;
        /// <summary>Use an unlit transparent material and a collider-free quad on a layer excluded from capture.</summary>
        public static SnitchPolaroid Spawn(Transform owner, Material material, ISnapFeedbackPolicy policy)
        {
            if (!material || !owner || !owner.TryGetComponent<MeshRenderer>(out var quad) || owner.GetComponent<SnitchPolaroid>()) return null;
            var view = owner.gameObject.AddComponent<SnitchPolaroid>();
            (view.quad, view.policy, view.audioSource) = (quad, policy, owner.GetComponent<AudioSource>());
            quad.enabled = false;
            view.image = new RenderTexture(256, 256, 0);
            quad.sharedMaterial = view.material = new Material(material) { mainTexture = view.image };
            return view;
        }
        public void Begin(string snap, Transform head, Texture preview)
        {
            if (!isActiveAndEnabled || !head || !preview || !image || policy?.AllowFeedback == false) return;
            var active = RenderTexture.active;
            try { Graphics.Blit(preview, image); } finally { RenderTexture.active = active; }
            this.head = head;
            if (audioSource) audioSource.Stop();
            card.Start(snap, Time.unscaledTimeAsDouble);
        }
        public void SetStatus(string snap, SnapStatus status)
        {
            if (card.SetStatus(snap, status, Time.unscaledTimeAsDouble) && status == SnapStatus.Sent && audioSource) audioSource.Play();
        }
        void LateUpdate()
        {
            if (!quad) return;
            if (!head || policy?.AllowFeedback == false) { OnDisable(); return; }
            var pose = card.Tick(Time.unscaledTimeAsDouble);
            if (!(quad.enabled = card.Visible)) return;
            transform.SetPositionAndRotation(head.position + head.rotation * pose.Offset, head.rotation);
            transform.localScale = new Vector3(pose.Width, pose.Width * 1.22f, 1);
            material.color = new Color(1, 1 - 0.78f * pose.Red, 1 - 0.82f * pose.Red, pose.Alpha);
        }
        void OnDisable() { card.Hide(); if (quad) quad.enabled = false; if (audioSource) audioSource.Stop(); }
        void OnDestroy() { Destroy(image); Destroy(material); }
    }
}
#endif
